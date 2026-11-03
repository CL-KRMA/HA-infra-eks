#!/bin/bash
# ============================================================
# destroy.sh
#
# Detruit COMPLETEMENT l'infrastructure (cluster EKS, noeuds, reseau,
# NAT Gateway, IAM...). Ordre des operations :
#
#   1. Acces API : si ton IP publique a change depuis le deploiement,
#      l'autorise sur l'API EKS (terraform apply cible sur le cluster,
#      equivalent de update-ip.sh sans toucher au reste).
#   2. Kubernetes : supprime les applications ArgoCD, les Ingress, les
#      releases Helm, les Services LoadBalancer et les PVC. Le NLB AWS
#      et les volumes EBS sont crees par Kubernetes (pas par Terraform) :
#      s'ils restent, `terraform destroy` bloque sur le VPC.
#   3. (uniquement avec --wait) Attend que les volumes EBS et les load
#      balancers du VPC aient reellement disparu cote AWS.
#   4. terraform destroy, lance IMMEDIATEMENT apres l'envoi des ordres de
#      suppression Kubernetes (sans attendre leur aboutissement), avec 3
#      tentatives. Entre deux tentatives, les load balancers orphelins du
#      VPC sont supprimes automatiquement.
#   5. Supprime le kubeconfig et terraform.tfvars locaux, puis verifie
#      qu'il ne reste rien de facturable (cluster, VPC, NAT Gateway,
#      Elastic IP, volumes EBS). Code de sortie 2 s'il reste quelque chose.
#   6. (uniquement avec --destroy-backend) supprime aussi le backend du
#      state : bucket S3 (toutes les versions) et cle KMS. Sans cette
#      option, le backend est TOUJOURS conserve (voir ci-dessous).
#
# Si le cluster est deja detruit, les etapes 1 a 3 sont ignorees et le
# script passe directement a terraform destroy.
#
# ATTENTION (mode rapide, par defaut) : comme on n'attend pas que le NLB
# et les volumes soient supprimes par Kubernetes, ils peuvent rester
# orphelins quand le cluster disparait. Les load balancers sont rattrapes
# par le script ; les volumes EBS orphelins sont signales a la fin.
# Utilise --wait pour le comportement le plus sur (plus lent).
#
# Usage (depuis n'importe quel dossier) :
#   ./scripts/destroy.sh          -> rapide, demande de taper le nom du cluster
#   ./scripts/destroy.sh -y       -> sans confirmation (automatisation)
#   ./scripts/destroy.sh --wait   -> attend la fin du nettoyage Kubernetes/AWS
#                                    avant terraform destroy (+5 a 15 min)
#   ./scripts/destroy.sh --destroy-backend
#                                 -> detruit AUSSI le bucket S3 de state et la
#                                    cle KMS, uniquement si tout le reste a ete
#                                    detruit sans reste. IRREVERSIBLE : demande
#                                    de taper le nom du bucket, meme avec -y.
#
# Backend (--destroy-backend) : passe par l'AWS CLI, donc fonctionne meme si
# le state local de terraform/bootstrap/ a ete perdu. La cle KMS n'est pas
# supprimee tout de suite : AWS impose un delai (ici 7 jours, le minimum),
# pendant lequel elle n'est plus facturee ni utilisable.
# ============================================================
set -euo pipefail

AUTO_YES=0
WAIT=0
DESTROY_BACKEND=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
    --wait) WAIT=1 ;;
    --destroy-backend) DESTROY_BACKEND=1 ;;
    *) echo "Option inconnue : $arg"; echo "Usage : $0 [-y|--yes] [--wait] [--destroy-backend]"; exit 1 ;;
  esac
done

# Options de suppression Kubernetes : sans --wait, on envoie les ordres et on n'attend pas.
if [ "$WAIT" -eq 1 ]; then
  HELM_WAIT="--wait --timeout 5m"
  KUBECTL_WAIT="--wait=true"
else
  HELM_WAIT=""
  KUBECTL_WAIT="--wait=false"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
KUBECONFIG_FILE="$PROJECT_ROOT/kubeconfig"

# --- Suppression du backend distant (option --destroy-backend) ---
BACKEND_BUCKET=""
BACKEND_REGION=""
BACKEND_KMS_ARN=""

# Lit une valeur "cle = \"valeur\"" dans terraform/backend.hcl
hcl_value() {
  awk -F'"' -v k="$1" '$0 ~ "^"k"[[:space:]]*=" {print $2; exit}' "$TERRAFORM_DIR/backend.hcl"
}

# Supprime toutes les versions (ou tous les delete markers) d'un bucket versionne
purge_bucket_objects() {
  local bucket="$1" region="$2" kind="$3" payload result
  while :; do
    payload="$(aws s3api list-object-versions --bucket "$bucket" --region "$region" \
      --max-items 1000 --query "{Objects: ${kind}[].{Key:Key,VersionId:VersionId}}" --output json)"
    echo "$payload" | grep -q '"Key"' || break
    result="$(aws s3api delete-objects --bucket "$bucket" --region "$region" --delete "$payload")"
    if echo "$result" | grep -q '"Errors"'; then
      echo "Erreur lors de la suppression d'objets :" >&2
      echo "$result" >&2
      return 1
    fi
  done
}

destroy_backend() {
  echo
  echo "[backend] Suppression du backend distant (bucket S3 + cle KMS)..."

  # Garde-fou : le state doit etre vide, sinon des ressources existent encore
  # et supprimer le state les rendrait impossibles a gerer avec Terraform.
  local remaining
  if ! remaining="$(cd "$TERRAFORM_DIR" && terraform state list 2>&1)"; then
    if echo "$remaining" | grep -qi "No state file was found"; then
      remaining=""
    else
      echo "Backend CONSERVE : impossible de lire le state :" >&2
      echo "$remaining" >&2
      return 1
    fi
  fi
  if [ -n "$remaining" ]; then
    echo "Backend CONSERVE : le state contient encore des ressources :" >&2
    echo "$remaining" >&2
    return 1
  fi

  echo "  - Suppression des versions d'objets du bucket $BACKEND_BUCKET"
  purge_bucket_objects "$BACKEND_BUCKET" "$BACKEND_REGION" "Versions" || return 1
  purge_bucket_objects "$BACKEND_BUCKET" "$BACKEND_REGION" "DeleteMarkers" || return 1

  echo "  - Suppression du bucket"
  aws s3api delete-bucket --bucket "$BACKEND_BUCKET" --region "$BACKEND_REGION" || return 1

  echo "  - Suppression de l'alias KMS et planification de la suppression de la cle"
  local alias_name key_state
  for alias_name in $(aws kms list-aliases --region "$BACKEND_REGION" --key-id "$BACKEND_KMS_ARN" \
      --query 'Aliases[].AliasName' --output text 2>/dev/null || true); do
    aws kms delete-alias --region "$BACKEND_REGION" --alias-name "$alias_name" || true
  done
  key_state="$(aws kms describe-key --region "$BACKEND_REGION" --key-id "$BACKEND_KMS_ARN" \
    --query KeyMetadata.KeyState --output text 2>/dev/null || echo Unknown)"
  case "$key_state" in
    PendingDeletion) echo "    Cle KMS deja en attente de suppression." ;;
    Unknown) echo "    Cle KMS introuvable ou inaccessible : verifie dans la console KMS." ;;
    *) aws kms schedule-key-deletion --region "$BACKEND_REGION" --key-id "$BACKEND_KMS_ARN" \
         --pending-window-in-days 7 > /dev/null \
       && echo "    Cle KMS planifiee pour suppression dans 7 jours." ;;
  esac

  echo "  - Nettoyage local (backend.hcl, state et cache Terraform)"
  rm -rf "$TERRAFORM_DIR/backend.hcl" "$TERRAFORM_DIR/.terraform" \
         "$TERRAFORM_DIR/bootstrap/.terraform" "$TERRAFORM_DIR"/bootstrap/terraform.tfstate*
  echo "  Backend supprime. Pour repartir de zero : ./scripts/bootstrap-backend.sh"
}

for cmd in terraform aws; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Erreur : '$cmd' est requis mais introuvable." >&2
    exit 1
  fi
done

# Identifiants AWS valides ? (SSO / credentials temporaires expires)
if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo "Erreur : identifiants AWS invalides ou expires (aws sts get-caller-identity a echoue)." >&2
  echo "Renouvelle-les (aws sso login, aws configure...) puis relance le script." >&2
  exit 1
fi

cd "$TERRAFORM_DIR"
if [ ! -f backend.hcl ]; then
  echo "Erreur : terraform/backend.hcl introuvable." >&2
  echo "Lance d'abord ./scripts/bootstrap-backend.sh (backend S3 du state)." >&2
  exit 1
fi

if [ "$DESTROY_BACKEND" -eq 1 ]; then
  BACKEND_BUCKET="$(hcl_value bucket)"
  BACKEND_REGION="$(hcl_value region)"
  BACKEND_KMS_ARN="$(hcl_value kms_key_id)"
  if [ -z "$BACKEND_BUCKET" ] || [ -z "$BACKEND_REGION" ] || [ -z "$BACKEND_KMS_ARN" ]; then
    echo "Erreur : bucket, region ou kms_key_id introuvable dans terraform/backend.hcl." >&2
    exit 1
  fi
  if [ ! -t 0 ]; then
    echo "Erreur : --destroy-backend demande une confirmation interactive (terminal requis)." >&2
    exit 1
  fi
fi

terraform init -input=false -backend-config=backend.hcl > /dev/null

CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null || true)"
REGION="$(terraform output -raw region 2>/dev/null || true)"
VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"
PROJECT_NAME="$(terraform output -raw project_name 2>/dev/null || true)"

if [ -z "$CLUSTER_NAME" ]; then
  echo "Aucun cluster dans le state Terraform (deja detruit, ou jamais cree)."
  echo "Lancement de terraform destroy pour nettoyer ce qui pourrait rester."
fi

# --- Confirmation ---
echo "============================================================"
echo " DESTRUCTION COMPLETE"
echo "   Cluster EKS : ${CLUSTER_NAME:-<aucun>}"
echo "   Region      : ${REGION:-<inconnue>}"
echo "   VPC         : ${VPC_ID:-<aucun>}"
echo " Toutes les donnees (volumes Prometheus/Grafana...) seront perdues."
echo "============================================================"
if [ "$AUTO_YES" -ne 1 ]; then
  read -r -p "Tape le nom du cluster (${CLUSTER_NAME:-yes}) pour confirmer : " ANSWER
  if [ "$ANSWER" != "${CLUSTER_NAME:-yes}" ]; then
    echo "Annule."
    exit 1
  fi
fi

# Confirmation du backend : toujours interactive, meme avec -y
if [ "$DESTROY_BACKEND" -eq 1 ]; then
  echo
  echo "============================================================"
  echo " SUPPRESSION DU BACKEND DISTANT (IRREVERSIBLE)"
  echo "   Bucket S3 : $BACKEND_BUCKET (toutes les versions du state)"
  echo "   Region    : $BACKEND_REGION"
  echo "   Cle KMS   : $BACKEND_KMS_ARN"
  echo " Le bucket et l'historique du state seront perdus definitivement."
  echo " La cle KMS sera supprimee apres 7 jours."
  echo " N'a lieu qu'apres la destruction complete du cluster, sans reste."
  echo "============================================================"
  read -r -p "Tape le nom exact du bucket pour confirmer : " ANSWER_BUCKET
  if [ "$ANSWER_BUCKET" != "$BACKEND_BUCKET" ]; then
    echo "Annule (rien n'a ete detruit)."
    exit 1
  fi
fi

# ============================================================
# 1. Autoriser l'IP publique actuelle sur l'API EKS
# ============================================================
# Equivalent de update-ip.sh, mais sans terraform apply complet :
# seul le cluster est modifie (public_access_cidrs), uniquement si
# l'IP actuelle n'est pas deja autorisee.
if [ -n "$CLUSTER_NAME" ]; then
  echo
  echo "[1/5] Verification de l'acces a l'API Kubernetes..."
  MY_IP="$(curl -s -4 --max-time 10 https://ifconfig.me || true)"
  CURRENT_CIDRS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text 2>/dev/null || true)"

  if [ -z "$CURRENT_CIDRS" ]; then
    echo "  Cluster introuvable cote AWS : etape ignoree."
  elif [ -z "$MY_IP" ]; then
    echo "  Impossible de detecter ton IP publique : etape ignoree."
  elif echo "$CURRENT_CIDRS" | grep -qE "(^|[[:space:]])(0\.0\.0\.0/0|${MY_IP}/32)([[:space:]]|$)"; then
    echo "  IP $MY_IP deja autorisee."
  else
    echo "  IP $MY_IP non autorisee (CIDR actuels : $CURRENT_CIDRS)."
    echo "  Mise a jour de l'acces API (quelques minutes)..."
    echo "allowed_api_cidr = \"${MY_IP}/32\"" > "$TERRAFORM_DIR/terraform.tfvars"
    terraform apply -auto-approve -input=false \
      -target=aws_eks_cluster.main -var "allowed_api_cidr=${MY_IP}/32"
  fi
fi

# ============================================================
# 2. Nettoyage cote Kubernetes
# ============================================================
K8S_OK=0
if [ -n "$CLUSTER_NAME" ] && command -v kubectl &> /dev/null && command -v helm &> /dev/null; then
  export KUBECONFIG="$KUBECONFIG_FILE"
  echo
  echo "[2/5] Connexion au cluster..."
  if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" \
       --kubeconfig "$KUBECONFIG_FILE" > /dev/null 2>&1 \
     && kubectl --request-timeout=20s get --raw /readyz > /dev/null 2>&1; then
    K8S_OK=1
  else
    echo "  Cluster injoignable (detruit ? probleme reseau/credentials AWS ?)."
    echo "  Nettoyage Kubernetes ignore."
  fi
else
  echo "[2/5] kubectl/helm absents ou cluster inconnu : nettoyage Kubernetes ignore."
fi

if [ "$K8S_OK" -eq 1 ]; then
  echo "  - Suppression des applications ArgoCD (guestbook...)"
  kubectl delete applications.argoproj.io --all -A --ignore-not-found --timeout=60s $KUBECTL_WAIT || true

  echo "  - Suppression des Ingress"
  kubectl delete ingress --all -A --ignore-not-found --timeout=60s $KUBECTL_WAIT || true

  echo "  - Desinstallation des releases Helm"
  helm list -A | tail -n +2 | awk '{print $1, $2}' | while read -r REL NS; do
    echo "      helm uninstall $REL -n $NS"
    helm uninstall "$REL" -n "$NS" $HELM_WAIT || true
  done

  echo "  - Suppression des Services LoadBalancer restants"
  kubectl get svc -A --no-headers 2>/dev/null \
    | awk '$3=="LoadBalancer"{print $1, $2}' \
    | while read -r NS SVC; do
        kubectl delete svc "$SVC" -n "$NS" --timeout=120s $KUBECTL_WAIT || true
      done

  echo "  - Suppression des PVC"
  kubectl delete pvc --all -A --ignore-not-found --timeout=180s $KUBECTL_WAIT || true

fi

# ==========================================================
# 3. Attendre la disparition reelle des ressources AWS (--wait)
# ==========================================================
if [ "$WAIT" -eq 1 ]; then
  echo
  echo "[3/5] Attente de la suppression des volumes et load balancers AWS..."

  if [ "$K8S_OK" -eq 1 ]; then
    for i in $(seq 1 30); do
      PV_COUNT=$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')
      [ "$PV_COUNT" -eq 0 ] && break
      echo "  PV restants : $PV_COUNT (tentative $i/30)"
      sleep 10
    done
  fi

  if [ -n "$VPC_ID" ] && [ -n "$REGION" ]; then
    for i in $(seq 1 60); do
      LB_V2=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true)
      LB_CLASSIC=$(aws elb describe-load-balancers --region "$REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || true)
      if [ -z "$LB_V2" ] && [ -z "$LB_CLASSIC" ]; then
        echo "  Aucun load balancer restant dans le VPC."
        break
      fi
      echo "  Load balancer(s) encore presents (tentative $i/60)..."
      sleep 10
    done
  fi
else
  echo
  echo "[3/5] Ignore (mode rapide : terraform destroy lance sans attendre)."
fi

# ============================================================
# 4. Terraform destroy
# ============================================================
echo
echo "[4/5] terraform destroy (10-15 minutes)..."
MAX_ATTEMPTS=3
DESTROY_OK=0
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "  Tentative $attempt/$MAX_ATTEMPTS"
  if terraform destroy -auto-approve -input=false; then
    DESTROY_OK=1
    break
  fi
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    echo "  terraform destroy a echoue (souvent : load balancer ou interfaces reseau restants)."
    if [ -n "$VPC_ID" ] && [ -n "$REGION" ]; then
      echo "  Suppression des load balancers orphelins du VPC..."
      for ARN in $(aws elbv2 describe-load-balancers --region "$REGION" \
          --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true); do
        aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$ARN" || true
      done
      for LBN in $(aws elb describe-load-balancers --region "$REGION" \
          --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || true); do
        aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$LBN" || true
      done
    fi
    echo "  Nouvelle tentative dans 120 secondes..."
    sleep 120
  fi
done

if [ "$DESTROY_OK" -ne 1 ]; then
  echo
  echo "ERREUR : terraform destroy a echoue apres $MAX_ATTEMPTS tentatives." >&2
  if [ -n "$VPC_ID" ] && [ -n "$REGION" ]; then
    echo "Interfaces reseau encore presentes dans le VPC $VPC_ID :" >&2
    aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' \
      --output text >&2 || true
  fi
  echo "Supprime les ressources restantes dans la console AWS (load balancers," >&2
  echo "volumes, interfaces reseau) puis relance : ./scripts/destroy.sh" >&2
  exit 1
fi

# ============================================================
# 5. Nettoyage local
# ============================================================
echo
echo "[5/5] Nettoyage des fichiers locaux..."
rm -f "$KUBECONFIG_FILE" "$TERRAFORM_DIR/terraform.tfvars"


# ============================================================
# Verification finale : reste-t-il quelque chose de facturable ?
# ============================================================
echo
echo "Verification finale des ressources AWS..."
LEFTOVERS=0
report() { echo "  [RESTE] $1"; LEFTOVERS=$((LEFTOVERS + 1)); }

if [ -n "$REGION" ]; then
  if [ -n "$CLUSTER_NAME" ] && aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1; then
    report "Cluster EKS '$CLUSTER_NAME' encore present"
  fi

  if [ -n "$VPC_ID" ]; then
    if aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" > /dev/null 2>&1; then
      report "VPC $VPC_ID encore present"
    fi
    NATS=$(aws ec2 describe-nat-gateways --region "$REGION" \
      --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=pending,available" \
      --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)
    [ -n "$NATS" ] && report "NAT Gateway : $NATS"
  fi

  if [ -n "$PROJECT_NAME" ]; then
    EIPS=$(aws ec2 describe-addresses --region "$REGION" \
      --filters "Name=tag:Project,Values=$PROJECT_NAME" \
      --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)
    [ -n "$EIPS" ] && report "Elastic IP : $EIPS"
  fi

  VOLS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
  [ -n "$VOLS" ] && report "Volume(s) EBS de PVC non attaches (verifie qu'ils viennent de ce projet) : $VOLS"
fi

echo
if [ "$LEFTOVERS" -eq 0 ]; then
  echo "Infrastructure detruite : aucune ressource restante detectee."
  if [ "$DESTROY_BACKEND" -eq 1 ]; then
    destroy_backend || {
      echo "ERREUR : la suppression du backend a echoue ou a ete refusee (voir ci-dessus)." >&2
      echo "Le cluster est detruit ; le backend est (au moins en partie) conserve." >&2
      exit 3
    }
  else
    echo "Backend de state (bucket S3 + cle KMS) conserve. Pour le supprimer aussi : --destroy-backend."
  fi
else
  echo "Destruction terminee MAIS $LEFTOVERS ressource(s) restante(s) detectee(s) ci-dessus."
  echo "Supprime-les dans la console AWS pour eviter d'etre facture."
  if [ "$DESTROY_BACKEND" -eq 1 ]; then
    echo "Backend de state CONSERVE (--destroy-backend ignore tant qu'il reste des ressources)."
  fi
  exit 2
fi
