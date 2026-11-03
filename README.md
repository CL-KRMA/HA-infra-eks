# HA-infra-eks-backends3 — Cluster Kubernetes EKS sur AWS (Terraform + Ansible)

Déploiement automatisé d'un cluster **Amazon EKS** avec Traefik (Ingress),
cert-manager + Let's Encrypt (TLS), ArgoCD (GitOps) et un stack de
monitoring (Prometheus + Grafana).

Terraform crée le réseau, le cluster EKS (control plane managé) et un
node group managé. Ansible déploie ensuite les composants applicatifs
avec `kubectl`/`helm` depuis ta machine (plus de SSH, plus de bastion).

## Backend Terraform (state distant S3)

Le state Terraform est stocké dans un bucket S3 versionné, chiffré par une
clé KMS dédiée, avec verrou natif (`use_lockfile`, **Terraform >= 1.11**,
pas besoin de DynamoDB).

```bash
./scripts/bootstrap-backend.sh   # une seule fois : crée bucket + clé KMS, génère terraform/backend.hcl,
                                 # migre l'éventuel state local vers S3
```

- `terraform/bootstrap/` : crée le bucket (state local, volontairement ; ne pas détruire).
  Le script est idempotent : si le bucket existe déjà (dossier local supprimé, nouvelle machine),
  il est réutilisé tel quel et seul `backend.hcl` est régénéré. Valeurs par défaut :
  projet `eks-cluster`, région `us-east-1` (surcharge via `TF_VAR_project_name` / `TF_VAR_region`).
  Après le premier lancement, committe `terraform/bootstrap/.terraform.lock.hcl`
  (versions exactes du provider, comme pour `terraform/.terraform.lock.hcl`).
- `terraform/backend.tf` + `backend.hcl` : configuration partielle du backend (`backend.hcl` n'est pas versionné).
- `update-ip.sh` et `destroy.sh` s'initialisent automatiquement avec `backend.hcl`.
- `destroy.sh` ne détruit **pas** le bucket de state ni la clé KMS, sauf avec
  l'option explicite `--destroy-backend` (voir « Détruire l'infrastructure »).
- **Dossier local perdu ou nouvelle machine** : récupère le projet, relance
  `./scripts/bootstrap-backend.sh` (le bucket existant est réutilisé, rien
  n'est recréé), puis `./scripts/update-ip.sh`. Lance toujours `update-ip.sh`
  et non `terraform apply` directement : sans `terraform.tfvars`,
  `allowed_api_cidr` retombe sur `0.0.0.0/0`.

## Architecture

- **VPC** unique, **3 AZ** (`az_count`, défaut 3), 6 subnets :
  - 3 subnets **publics** (un par AZ) : Internet Gateway, NAT Gateway,
    Network Load Balancer (créé par le Service Traefik).
  - 3 subnets **privés** (un par AZ) : noeuds EKS (pas d'IP publique),
    sortie Internet via **un NAT Gateway** par défaut
    (`nat_per_az = false`) ou **un NAT par AZ** (`nat_per_az = true`).
  - Le node group répartit lui-même les noeuds sur les subnets privés :
    3 noeuds = 1 par AZ.
- **EKS** : control plane managé (API server + etcd gérés par AWS).
  Endpoint API public restreint à `allowed_api_cidr` + endpoint privé.
- **Node group managé** : 3 noeuds `m5.large` par défaut (min 3, max 6),
  AMI Amazon Linux 2023, dans les subnets privés.
- **Add-ons** : EBS CSI driver (via EKS Pod Identity) pour les volumes
  persistants ; StorageClass `gp3` par défaut.
- **Traefik** (Helm, 3 réplicas répartis par zone) exposé par un **NLB AWS** (cross-zone) : un seul
  hostname, à utiliser en **CNAME** pour tes domaines.
- **cert-manager** + **Let's Encrypt** (challenge HTTP-01 via Traefik).
- **ArgoCD** sur `argocd.domain.com`, **Grafana** sur
  `monitoring.domain.com` (HTTPS).

## Structure du projet

```
HA-infra-eks-backends3/
├── terraform/
│   ├── main.tf              # VPC, subnets, NAT, EKS, node group, add-ons
│   ├── backend.tf           # Backend S3 (configuration partielle)
│   ├── backend.hcl.example  # Modèle ; backend.hcl est généré (non versionné)
│   ├── bootstrap/
│   │   └── main.tf          # Bucket S3 + clé KMS du state (appliqué une seule fois)
│   └── .terraform.lock.hcl  # Versions exactes des providers (versionné)
├── ansible/
│   ├── ansible.cfg
│   ├── hosts                # Inventaire : localhost uniquement
│   ├── site.yml             # Orchestrateur
│   ├── group_vars/all/
│   │   └── vars.yml         # cluster_name, region, domaines, versions
│   ├── secrets/
│   │   └── vault.yml.example  # Template du secret Grafana (à copier + chiffrer)
│   └── playbooks/
│       ├── install-terraform.yml    # Terraform seul
│       ├── configure-cluster.yml    # kubeconfig, attente noeuds, StorageClass gp3
│       ├── install-traefik.yml      # Ingress controller + NLB
│       ├── install-cert-manager.yml # cert-manager + ClusterIssuer Let's Encrypt
│       ├── install-argocd.yml
│       ├── install-monitoring.yml
│       └── guestbook.yml            # App de démo ArgoCD
├── scripts/
│   ├── bootstrap-backend.sh # Crée le backend S3 du state, génère backend.hcl, migre le state local
│   ├── update-ip.sh         # Détecte ton IP, l'autorise sur l'API, terraform apply
│   ├── destroy.sh           # Détruit TOUTE l'infra (k8s + terraform destroy)
│   ├── set-domain.sh        # Remplace domain.com par ton propre domaine
│   └── show-dns.sh          # Affiche les CNAME DNS à créer (hostname du NLB)
├── .github/
│   └── workflows/
│       └── ci.yml           # CI : Terraform, Ansible, scripts (aucun secret requis)
├── .gitignore
├── .gitattributes
└── README.md
```

## Prérequis

Sur la machine de contrôle :

- **Credentials AWS** configurés (`~/.aws/credentials` ou variables
  d'environnement) avec les droits de créer VPC, EKS et IAM, ainsi que
  `s3:*` sur le bucket de state et `kms:*` sur sa clé (création, utilisation
  et, pour `--destroy-backend`, suppression). Le plus simple : un profil
  administrateur.
  ⚠️ L'identité qui lance `terraform apply` devient **admin du cluster** :
  c'est la même qui doit être utilisée pour lancer Ansible.
- **Ansible** (fournit aussi `ansible-vault`) : seul prérequis à installer
  à la main (`sudo apt install ansible` ou `pipx install ansible-core`).
- **Terraform >= 1.11**, **AWS CLI v2**, **kubectl** et **Helm 3** : installés
  automatiquement par l'étape 0 ci-dessous (Ubuntu/Debian). Sur un autre
  système, installe-les à la main.
- `curl` (utilisé par `scripts/update-ip.sh`).
- **Domaine** : le projet utilise `argocd.domain.com` et
  `monitoring.domain.com` comme exemples, à remplacer avec
  `./scripts/set-domain.sh mondomaine.fr`.
- **Mot de passe Grafana (ansible-vault)** : voir étape 3 — le playbook
  monitoring refuse de s'exécuter tant qu'il n'est pas configuré.

## Déploiement — étapes

```bash
# 0. Installer les prérequis sur cette machine (Ubuntu/Debian) :
apt install Terraform, AWS CLI v2, kubectl, Helm 3, curl, unzip

# 0bis. Configurer tes credentials AWS et vérifier
aws configure          # ou : aws sso login
aws sts get-caller-identity

# 1a. Rendre les scripts exécutables (une seule fois)
chmod +x scripts/*.sh

# 1b. ⚠️ OBLIGATOIRE : remplacer le domaine d'exemple (domain.com) par le
#     tien. Sans ça, Let's Encrypt ne pourra jamais émettre de certificat.
./scripts/set-domain.sh mondomaine.fr
grep hostname ansible/group_vars/all/vars.yml   # vérifier le résultat

# 1c. Créer le backend S3 du state Terraform (une seule fois)
./scripts/bootstrap-backend.sh

# 2. Détecter son IP publique et appliquer le Terraform
#    (terraform init, génère terraform/terraform.tfvars, puis terraform apply :
#    tape "yes" pour confirmer ; ajouter -y pour ignorer la confirmation).
#    La création du cluster EKS prend ~10-15 minutes.
./scripts/update-ip.sh

# Vérifier le réseau (depuis la racine du projet)
terraform -chdir=terraform output availability_zones
terraform -chdir=terraform output nat_gateway_count    # doit afficher 1

# 3. Configurer le mot de passe Grafana (ansible-vault, une fois)
cp ansible/secrets/vault.yml.example ansible/secrets/vault.yml
nano ansible/secrets/vault.yml
# -> remplacer grafana_admin_password par un vrai mot de passe AVANT de
#    chiffrer (sinon le playbook refusera la valeur placeholder).
ansible-vault encrypt ansible/secrets/vault.yml
# -> Ansible demande un mot de passe de VAULT (à retenir, différent du
#    mot de passe Grafana) : celui de chaque --ask-vault-pass.

# 4. Kubeconfig + StorageClass + Traefik (NLB)
#    Si Ansible affiche "Ansible is being run in a world writable directory ...
#    ignoring it as an ansible.cfg source", ansible.cfg est ignoré (inventaire
#    non chargé -> 'kubeconfig_path' is undefined). Retire d'abord l'écriture
#    pour group/other sur le projet (depuis la racine du projet) :
chmod -R go-w "$(pwd)"
cd ansible
ansible-playbook site.yml --tags cluster,ingress --ask-vault-pass

# Vérifier : 3 noeuds Ready, 1 par zone, Traefik réparti (depuis le dossier ansible/)
export KUBECONFIG=$PWD/../kubeconfig
kubectl get nodes -L topology.kubernetes.io/zone
kubectl -n traefik get pods -o wide
```

### Étape 5 — DNS (obligatoire avant l'étape 6)

> ⚠️ **STOP : sans les CNAME, le certificat TLS reste indéfiniment « non
> Ready »** (Let's Encrypt ne peut pas valider le domaine).

Les enregistrements à créer sont des **CNAME** vers le hostname du NLB
Traefik. **Pas d'adresse IP** : celles d'un NLB AWS changent.

**5a. Afficher les enregistrements à créer** (depuis le dossier `ansible/`) :

```bash
../scripts/show-dns.sh
```

Exemple de résultat (le hostname du NLB sera le tien) :

```
Enregistrements DNS a creer chez ton registrar (type CNAME, pas d'IP) :

  TYPE     NOM          VALEUR
  CNAME    argocd       xxxx.elb.us-east-1.amazonaws.com
  CNAME    monitoring   xxxx.elb.us-east-1.amazonaws.com

Noms complets : argocd.mondomaine.fr et monitoring.mondomaine.fr
```

Le hostname du NLB est aussi affiché à la fin de l'étape 4, ou avec :

```bash
kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**5b. Créer ces 2 enregistrements chez ton registrar** (interface web de
ton fournisseur de domaine) : type `CNAME`, nom `argocd` puis `monitoring`,
valeur = le hostname du NLB. Selon le registrar, le champ « nom » attend
`argocd` ou `argocd.mondomaine.fr`. Cloudflare : mets le proxy sur
« DNS only » (nuage gris).

**5c. Attendre la propagation et vérifier** que les noms résolvent vers le
NLB (le challenge HTTP-01 de Let's Encrypt passe par ce NLB, port 80) :

```bash
nslookup argocd.mondomaine.fr
nslookup monitoring.mondomaine.fr
```

### Étape 6 — cert-manager + ArgoCD + Monitoring + démo

```bash
# Depuis le dossier ansible/
ansible-playbook site.yml --skip-tags cluster,ingress \
  -e letsencrypt_email=TON_VRAI_EMAIL@TON_DOMAINE.com --ask-vault-pass
```

> ⚠️ `letsencrypt_email` doit être une **vraie adresse email que tu
> possèdes**. Let's Encrypt rejette les domaines `example.com` /
> `example.org` / `example.net`.

Pour ne rejouer qu'une étape (depuis le dossier `ansible/`) :

```bash
ansible-playbook site.yml --tags cluster --ask-vault-pass
ansible-playbook site.yml --tags ingress --ask-vault-pass
ansible-playbook site.yml --tags cert-manager -e letsencrypt_email=TON_VRAI_EMAIL@TON_DOMAINE.com --ask-vault-pass
ansible-playbook site.yml --tags argocd --ask-vault-pass
ansible-playbook site.yml --tags monitoring --ask-vault-pass
```

> `--ask-vault-pass` est à passer à **toutes** les commandes
> `ansible-playbook site.yml`, même avec `--tags` : Ansible lit
> `ansible/secrets/vault.yml` (chiffré) pour tout le projet, sinon
> erreur « Attempting to decrypt but no vault secrets found ».
> Alternative non interactive : `--vault-password-file=<chemin>`
> (fichier à ne JAMAIS committer, couvert par `.gitignore`).

Pour modifier le mot de passe Grafana après chiffrement :

```bash
export EDITOR=nano
ansible-vault edit ansible/secrets/vault.yml
```

### Piloter le cluster depuis ta machine

Ansible génère `kubeconfig` à la **racine du projet** (ignoré par git, et
sans toucher à `~/.kube/config`). Pour l'utiliser, depuis la racine du
projet (depuis `ansible/`, le chemin est `$PWD/../kubeconfig`) :

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

Ou pour fusionner dans ton kubeconfig habituel :
`aws eks update-kubeconfig --name eks-cluster --region us-east-1`.

### Accéder à ArgoCD et Grafana

- **ArgoCD** : `https://argocd.<tondomaine>/` — utilisateur `admin`,
  mot de passe :
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d && echo
  ```
- **Grafana** : `https://monitoring.<tondomaine>/` — utilisateur `admin`,
  mot de passe défini dans `ansible/secrets/vault.yml` (étape 3).

## Personnalisation

- **Où modifier les variables Terraform** : directement les valeurs
  `default` dans `terraform/main.tf`. Ne mets pas tes réglages dans
  `terraform/terraform.tfvars` : `scripts/update-ip.sh` réécrit ce fichier
  à chaque lancement (il ne contient que `allowed_api_cidr`).
- **Nom du cluster / région** : `cluster_name` et `region` dans
  `terraform/main.tf` doivent correspondre à `cluster_name` et
  `aws_region` dans `ansible/group_vars/all/vars.yml`.
- **Taille du cluster** : `node_desired_size`, `node_min_size`,
  `node_max_size`, `instance_type` (variables Terraform). Garde
  `node_min_size >= az_count` pour avoir au moins un noeud par AZ.
- **AZ et NAT** : `az_count` (défaut 3, minimum 2 imposé par EKS) et
  `nat_per_az` (défaut `false`).
- **Version Kubernetes** : `kubernetes_version` (défaut `1.35`). EKS
  facture le *support étendu* au-delà de la fin du support standard :
  vérifie les dates avec `aws eks describe-cluster-versions`.
- **CIDR des subnets** : les pods utilisent des IP du VPC (VPC CNI),
  garde des `/24` au minimum pour les subnets privés. Si tu changes
  `az_count`, adapte aussi les deux listes de CIDR (même longueur).

## Sécurité — à savoir avant un usage réel

- ✅ **API Kubernetes restreinte à `allowed_api_cidr`** (IP publique de la
  machine de contrôle, positionnée par `scripts/update-ip.sh`). Sans le
  script, le défaut est `0.0.0.0/0` : à restreindre.
- ✅ **Mot de passe Grafana chiffré via `ansible-vault`**.
- ✅ **Noeuds sans IP publique**, volumes EBS chiffrés (StorageClass `gp3`).
- **ArgoCD en HTTP côté service** (`server.insecure=true`) : le TLS est
  terminé par Traefik, seul le trajet interne Ingress → pod reste en clair.
- **Le NLB est public** (ports 80/443 ouverts à Internet) : seuls les
  hostnames routés par les Ingress répondent.
- **NAT Gateway unique par défaut** (`nat_per_az = false`) : une panne de
  son AZ coupe la sortie Internet des noeuds (pas le trafic entrant ni le
  control plane). Pour une sortie résiliente, passer `nat_per_az = true`
  (un NAT par AZ).
- **Volumes EBS liés à une AZ** : les PVC (Prometheus, Grafana) sont
  attachés à l'AZ où ils ont été créés. Si cette AZ tombe, le pod ne peut
  pas redémarrer ailleurs avec ses données (la haute disponibilité du
  stockage de monitoring n'est pas couverte).
- **cert-manager / Let's Encrypt** : `letsencrypt-prod` est soumis aux
  [rate limits](https://letsencrypt.org/docs/rate-limits/) — utiliser
  `letsencrypt-staging` pour les tests répétés.
- ✅ **State Terraform distant** : bucket S3 versionné, chiffré KMS, accès
  public bloqué, HTTP refusé, verrou natif. Le state est ainsi hors de la
  machine de contrôle.
- **Pas de NetworkPolicy ni de RBAC fin** : l'identité créatrice est admin
  du cluster. À durcir avant un usage multi-utilisateurs.
- **Coûts** : le control plane EKS, le ou les NAT Gateways, le NLB et les
  noeuds sont facturés tant que l'infra existe. `./scripts/destroy.sh`
  supprime tout cela. Seuls restent le bucket de state et la clé KMS (environ
  1 $/mois au total, essentiellement la clé), sauf si tu utilises
  `--destroy-backend`.

  Ordre de grandeur en `us-east-1`, 24 h/24 (**estimations à vérifier avec
  l'[AWS Pricing Calculator](https://calculator.aws/)**, les prix évoluent) :

  | Configuration | ≈ par mois | ≈ par heure |
  |---|---|---|
  | 3 AZ, 1 NAT (défaut) | ~355 $ | ~0,49 $ |
  | 3 AZ, 3 NAT (`nat_per_az = true`) | ~425–430 $ | ~0,59 $ |

  Pour un test de quelques heures, compte environ 1 à 3 $ : détruis le
  cluster dès que tu as fini.

## Détruire l'infrastructure

Depuis la racine du projet :

```bash
./scripts/destroy.sh          # rapide : demande de taper le nom du cluster
./scripts/destroy.sh -y       # sans confirmation
./scripts/destroy.sh --wait   # plus sûr, plus lent (voir ci-dessous)
./scripts/destroy.sh --destroy-backend   # détruit AUSSI le backend de state (voir plus bas)
```

Ce que fait le script :

1. **Accès API** : si ton IP publique a changé depuis le déploiement, il
   l'autorise sur l'API EKS (pas besoin de relancer `update-ip.sh`).
2. **Nettoyage Kubernetes** : il supprime les applications ArgoCD, les
   Ingress, les releases Helm, les Services LoadBalancer (donc le NLB) et
   les PVC (donc les volumes EBS). Ces ressources sont créées par
   Kubernetes, pas par Terraform : si elles restent, `terraform destroy`
   bloque sur le VPC.
3. **`terraform destroy`**, jusqu'à 3 tentatives. Entre deux tentatives,
   les load balancers orphelins du VPC sont supprimés automatiquement.
4. **Nettoyage local** (`kubeconfig`, `terraform.tfvars`) puis
   **vérification finale** : il contrôle qu'il ne reste ni cluster, VPC,
   NAT Gateway, Elastic IP ni volume EBS de PVC. Code de sortie `2` s'il
   reste quelque chose.
5. **Backend** (uniquement avec `--destroy-backend`) : voir ci-dessous.

**Mode rapide (défaut)** : le script envoie les ordres de suppression
Kubernetes puis lance `terraform destroy` sans attendre qu'ils aboutissent
(12 à 18 minutes au total). **Avec `--wait`**, il attend la suppression
réelle du NLB et des volumes avant `terraform destroy` (20 à 30 minutes).

Si le script s'arrête sur une erreur, supprime à la main dans la console
AWS les load balancers, volumes EBS `pvc-…` et interfaces réseau restants,
puis relance-le : il reprend avec ce qu'il reste dans le state.

⚠️ Le script **ne supprime pas tes enregistrements DNS** (CNAME) : à
retirer chez ton fournisseur de domaine.

⚠️ Par défaut, il **ne supprime pas le backend** (bucket S3 + clé KMS de
`terraform/bootstrap/`) : le state reste disponible pour recréer le cluster.

### Supprimer aussi le backend (`--destroy-backend`)

```bash
./scripts/destroy.sh --destroy-backend
```

À utiliser quand tu abandonnes définitivement le projet. **Irréversible** :
l'historique du state est perdu.

- **Garde-fous** : le script te demande de taper le **nom exact du bucket**
  (même avec `-y`, et il exige un terminal interactif). Le backend n'est
  supprimé **qu'après** la destruction complète du cluster, sans reste
  détecté et avec un state Terraform vide. Sinon il est conservé.
- **Ce qui est supprimé** : toutes les versions et marqueurs de suppression
  du bucket, le bucket, l'alias KMS, puis la clé KMS est **planifiée pour
  suppression dans 7 jours** (délai minimal imposé par AWS ; elle n'est plus
  facturée pendant ce délai). Les fichiers locaux `backend.hcl`,
  `terraform/.terraform/` et le state de `bootstrap/` sont effacés.
- Il passe par l'AWS CLI, donc fonctionne même si le state local de
  `terraform/bootstrap/` est perdu. Les valeurs viennent de `backend.hcl`.
- **Codes de sortie** : `2` s'il reste des ressources facturables (backend
  conservé) ; `3` si le cluster est détruit mais que la suppression du
  backend a échoué ou été refusée.
- Pour repartir de zéro ensuite : `./scripts/bootstrap-backend.sh`. Le nom du
  bucket peut mettre quelques minutes à redevenir disponible.

## Dépannage rapide

- `destroy.sh --destroy-backend` termine avec le code `3` → le cluster est
  détruit mais le backend n'a pas pu être supprimé (state non vide, erreur
  S3/KMS). Lis le message, corrige, puis relance la même commande.
- `terraform/backend.hcl introuvable` (`update-ip.sh`, `destroy.sh`) → lance
  `./scripts/bootstrap-backend.sh`.
- `Error acquiring the state lock` → un autre `apply` tourne, ou le
  précédent a été interrompu. Si tu es sûr qu'aucun ne tourne :
  `cd terraform && terraform force-unlock <LOCK_ID>`.
- `bootstrap-backend.sh` : `alias KMS ... introuvable` → le bucket existe mais
  pas sous le même projet/région. Exporte `TF_VAR_project_name` et
  `TF_VAR_region` avec les valeurs d'origine, puis relance.
- `Unsupported argument "use_lockfile"` → Terraform trop ancien :
  `terraform -version` doit afficher 1.11 ou plus.
- `kubectl`/`helm` : `Unable to connect` ou timeout → ton IP publique a
  changé : relance `./scripts/update-ip.sh` pour mettre à jour
  `allowed_api_cidr`.
- `destroy.sh` : `identifiants AWS invalides ou expirés` → renouvelle-les
  (`aws sso login`, `aws configure`) puis relance le script.
- `You must be logged in to the server (Unauthorized)` → tu n'utilises pas
  l'identité AWS qui a lancé `terraform apply` (seule admin par défaut).
- PVC `Pending` → vérifier le driver : `kubectl -n kube-system get pods
  | grep ebs-csi` et l'add-on : `aws eks describe-addon --cluster-name
  eks-cluster --addon-name aws-ebs-csi-driver`.
- `EXTERNAL-IP` du Service Traefik en `<pending>` → attendre quelques
  minutes, puis `kubectl -n traefik describe svc traefik` (les subnets
  publics doivent porter le tag `kubernetes.io/role/elb`).
- Certificat TLS jamais `Ready` (`kubectl describe certificate -n argocd
  argocd-server-tls` ou `-n monitoring grafana-tls`) → **cause n°1 : DNS
  absent ou domaine encore `domain.com`**. Vérifier :
  ```bash
  grep hostname ansible/group_vars/all/vars.yml   # domaine remplacé ?
  ./scripts/show-dns.sh                           # CNAME à créer
  nslookup argocd.mondomaine.fr                   # résout vers le NLB ?
  kubectl describe challenge -A
  kubectl logs -n cert-manager deploy/cert-manager
  ```
  Avec un NLB, l'auto-vérification de cert-manager (depuis un pod vers le
  NLB) peut échouer par intermittence ; elle est retentée automatiquement.
  Une fois le DNS propagé, forcer une nouvelle demande :
  ```bash
  kubectl delete certificate argocd-server-tls -n argocd
  kubectl delete secret argocd-server-tls -n argocd --ignore-not-found
  cd ansible && ansible-playbook site.yml --tags argocd --ask-vault-pass
  ```
  (Même chose avec `grafana-tls` / `-n monitoring` et `--tags monitoring`.)
- `FAILED - RETRYING: Attendre que le certificat TLS ArgoCD soit Ready` puis
  `[ERROR]` sur cette tâche → **non bloquant** : la tâche a
  `failed_when: false`, le playbook continue. ArgoCD est bien installé ;
  seul le certificat n'est pas encore émis (voir ci-dessus : DNS).
- `Attempting to decrypt but no vault secrets found` → `vault.yml` est
  chiffré et le mot de passe n'a pas été fourni. Ajoute `--ask-vault-pass`
  (ou `--vault-password-file=<chemin>`) à **toute** commande
  `ansible-playbook site.yml`, même avec `--tags`. Mot de passe du vault
  oublié : recréer le fichier (`cp vault.yml.example vault.yml`, éditer,
  `ansible-vault encrypt`).
- `dial tcp: lookup ... on 10.255.255.254:53: i/o timeout` (helm repo add,
  etc.) → DNS cassé dans **WSL2**. Test : `nslookup github.com`. Depuis
  PowerShell : `wsl --shutdown`, puis rouvre le terminal. Si ça revient :
  dans `/etc/wsl.conf` mettre `[network]` / `generateResolvConf = false`,
  puis `sudo rm /etc/resolv.conf` et
  `printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf`.
  Désactive aussi un éventuel VPN pour tester.
- `terraform apply` interrompu ou sortie coupée pendant la création du
  cluster EKS (10-15 min, normal) → ne pas conclure à une erreur. Vérifie
  `aws eks describe-cluster --name eks-cluster --query cluster.status`
  (`CREATING` / `ACTIVE`), puis relance `terraform apply` : il reprend là
  où il s'est arrêté. Si le node group échoue, vérifie le quota vCPU :
  `aws service-quotas get-service-quota --service-code ec2
  --quota-code L-1216C47A --region us-east-1` (3 × m5.large = 6 vCPU).
