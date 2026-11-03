#!/bin/bash
set -e

# Usage : ./scripts/update-ip.sh [-y|--yes]
#   (sans option) : affiche le plan Terraform et demande confirmation
#   -y, --yes     : applique sans confirmation (utile en automatisation)
#
# Detecte l'IP publique de la machine de controle et la positionne comme
# seul CIDR autorise a joindre l'API Kubernetes publique du cluster EKS
# (variable allowed_api_cidr), puis lance terraform apply.
AUTO_APPROVE=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_APPROVE="-auto-approve" ;;
    *) echo "Option inconnue : $arg"; echo "Usage : $0 [-y|--yes]"; exit 1 ;;
  esac
done

# Le script vit dans scripts/, le code Terraform dans ../terraform
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
cd "$TERRAFORM_DIR"

# Idempotent : rapide si déjà initialisé, répare ou installe sinon
# (providers manquants, version changée, lock file mis à jour, etc.)
if [ ! -f backend.hcl ]; then
  echo "Erreur : terraform/backend.hcl introuvable." >&2
  echo "Lance d'abord ./scripts/bootstrap-backend.sh (backend S3 du state)." >&2
  exit 1
fi
terraform init -input=false -backend-config=backend.hcl

MY_IP=$(curl -s -4 https://ifconfig.me)

if [ -z "$MY_IP" ]; then
  echo "Erreur : impossible de récupérer l'IP publique"
  exit 1
fi

echo "IP détectée : $MY_IP"
echo "allowed_api_cidr = \"${MY_IP}/32\"" > terraform.tfvars

# Sans -y : Terraform affiche le plan et demande de taper "yes"
terraform apply $AUTO_APPROVE
