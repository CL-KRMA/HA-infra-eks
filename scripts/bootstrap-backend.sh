#!/bin/bash
set -euo pipefail

# Usage : ./scripts/bootstrap-backend.sh [options passees a terraform apply, ex: -auto-approve]
#
# 1. Si le bucket de state n'existe pas encore : le cree avec la cle KMS
#    (terraform/bootstrap, state local).
#    S'il existe deja (ex: dossier local supprime, nouvelle machine) :
#    il est reutilise tel quel, rien n'est recree.
# 2. Genere terraform/backend.hcl avec les valeurs de ton compte.
# 3. Initialise le code principal sur ce backend. Si un state local existe
#    (terraform/terraform.tfstate), il est migre vers S3.
#
# Idempotent : relancable sans risque.
#
# Valeurs par defaut = celles de terraform/bootstrap/main.tf. Pour les
# changer, exporte les memes variables avant de lancer le script :
#   TF_VAR_project_name, TF_VAR_region, TF_VAR_state_key

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
BOOTSTRAP_DIR="$TERRAFORM_DIR/bootstrap"

PROJECT_NAME="${TF_VAR_project_name:-eks-cluster}"
REGION="${TF_VAR_region:-us-east-1}"
STATE_KEY="${TF_VAR_state_key:-eks/terraform.tfstate}"

for cmd in terraform aws; do
  command -v "$cmd" >/dev/null || { echo "Erreur : '$cmd' est requis." >&2; exit 1; }
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "Erreur : identifiants AWS invalides ou expires." >&2; exit 1; }

BUCKET="${PROJECT_NAME}-tfstate-${ACCOUNT_ID}-${REGION}"
KMS_ALIAS="alias/${PROJECT_NAME}-tfstate"

# --- Le bucket existe-t-il deja ? ---
BUCKET_EXISTS=false
if out="$(aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>&1)"; then
  BUCKET_EXISTS=true
elif echo "$out" | grep -qE "404|Not Found|NoSuchBucket"; then
  BUCKET_EXISTS=false
else
  echo "Erreur : impossible de verifier le bucket '$BUCKET' :" >&2
  echo "  $out" >&2
  exit 1
fi

if [ "$BUCKET_EXISTS" = true ] && [ ! -f "$BOOTSTRAP_DIR/terraform.tfstate" ]; then
  # Backend deja cree, mais le state local du bootstrap est perdu :
  # on reutilise l'existant au lieu de tout recreer (ce qui echouerait).
  echo "[1/3] Bucket '$BUCKET' deja present -> reutilise (rien n'est recree)."
  KMS_ARN="$(aws kms describe-key --region "$REGION" --key-id "$KMS_ALIAS" \
    --query KeyMetadata.Arn --output text 2>/dev/null)" || {
    echo "Erreur : le bucket existe mais l'alias KMS '$KMS_ALIAS' est introuvable." >&2
    echo "Verifie la region et le nom de projet (TF_VAR_project_name / TF_VAR_region)." >&2
    exit 1; }
else
  echo "[1/3] Creation / mise a jour du bucket de state (terraform/bootstrap)..."
  cd "$BOOTSTRAP_DIR"
  terraform init -input=false
  terraform apply -input=false "$@"
  KMS_ARN="$(terraform output -raw kms_key_arn)"
  BUCKET="$(terraform output -raw bucket)"
  REGION="$(terraform output -raw region)"
  STATE_KEY="$(terraform output -raw state_key)"
fi

echo "[2/3] Generation de terraform/backend.hcl..."
cat > "$TERRAFORM_DIR/backend.hcl" <<HCL
bucket       = "${BUCKET}"
key          = "${STATE_KEY}"
region       = "${REGION}"
encrypt      = true
kms_key_id   = "${KMS_ARN}"
use_lockfile = true
HCL

echo "[3/3] Initialisation du backend dans terraform/..."
cd "$TERRAFORM_DIR"
if [ -f terraform.tfstate ]; then
  echo "  State local detecte -> migration vers S3."
  cp terraform.tfstate "terraform.tfstate.pre-s3-backup"
  terraform init -input=false -migrate-state -force-copy -backend-config=backend.hcl
  echo "  Sauvegarde locale conservee : terraform/terraform.tfstate.pre-s3-backup"
  echo "  Verifie 'terraform plan' (aucun changement attendu), puis supprime-la."
else
  terraform init -input=false -backend-config=backend.hcl
fi

echo "Termine. State distant : s3://${BUCKET}/${STATE_KEY}"
