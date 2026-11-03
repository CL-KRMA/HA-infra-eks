#!/bin/bash
# ============================================================
# set-domain.sh
#
# Remplace le domaine placeholder "domain.com" par le domaine
# fourni en parametre dans tous les fichiers du projet qui
# l'utilisent (Ansible playbooks + README).
#
# Fichiers concernes :
#   - ansible/group_vars/all/vars.yml            (argocd_hostname, monitoring_hostname)
#   - ansible/playbooks/install-cert-manager.yml (email par defaut, doc)
#   - ansible/site.yml                            (commentaire doc)
#   - README.md                                   (doc)
#
# Usage (depuis n'importe quel dossier, le script se repere lui-meme) :
#   ./scripts/set-domain.sh domain.com
#
# Une sauvegarde .bak est creee a cote de chaque fichier modifie.
# ============================================================
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage : $0 <domaine>" >&2
  echo "Exemple : $0 domain.com" >&2
  exit 1
fi

NEW_DOMAIN="$1"
OLD_DOMAIN="domain.com"

# Validation simple du format de domaine (label.label...)
if ! [[ "$NEW_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
  echo "Erreur : '$NEW_DOMAIN' ne ressemble pas a un domaine valide (ex: domain.com)." >&2
  exit 1
fi

# Le script vit dans scripts/, la racine du projet est le dossier parent
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FILES=(
  "$PROJECT_ROOT/ansible/group_vars/all/vars.yml"
  "$PROJECT_ROOT/ansible/playbooks/install-cert-manager.yml"
  "$PROJECT_ROOT/ansible/site.yml"
  "$PROJECT_ROOT/README.md"
)

echo "Domaine cible : $NEW_DOMAIN (remplace '$OLD_DOMAIN')"
echo

CHANGED=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "Attention : fichier introuvable, ignore : $f" >&2
    continue
  fi

  if ! grep -q "$OLD_DOMAIN" "$f"; then
    echo "  (rien a remplacer dans ${f#$PROJECT_ROOT/})"
    continue
  fi

  cp "$f" "${f}.bak"
  sed -i.tmp "s/${OLD_DOMAIN}/${NEW_DOMAIN}/g" "$f"
  rm -f "${f}.tmp"
  echo "  modifie : ${f#$PROJECT_ROOT/}  (sauvegarde : ${f#$PROJECT_ROOT/}.bak)"
  CHANGED=$((CHANGED + 1))
done

echo
if [ "$CHANGED" -eq 0 ]; then
  echo "Aucun fichier modifie (deja a jour, ou placeholder '$OLD_DOMAIN' absent)."
else
  echo "$CHANGED fichier(s) mis a jour avec le domaine '$NEW_DOMAIN'."
  echo
  echo "Prochaine etape : apres l'etape 'ingress' (Traefik), cree des CNAME"
  echo "vers le hostname du NLB (kubectl -n traefik get svc traefik) pour :"
  echo "  - argocd.${NEW_DOMAIN}"
  echo "  - monitoring.${NEW_DOMAIN}"
fi
