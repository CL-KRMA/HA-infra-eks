#!/bin/bash
# ============================================================
# show-dns.sh
#
# Affiche les enregistrements DNS a creer chez ton registrar,
# a partir du domaine configure (set-domain.sh) et du NLB Traefik.
#
# IMPORTANT : on ne donne PAS d'adresse IP. Un NLB AWS a des IP qui
# changent : il faut des enregistrements de type CNAME vers son
# hostname (xxxx.elb.<region>.amazonaws.com).
#
# Usage (depuis n'importe quel dossier) :
#   ./scripts/show-dns.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VARS="$PROJECT_ROOT/ansible/group_vars/all/vars.yml"
export KUBECONFIG="$PROJECT_ROOT/kubeconfig"

if [ ! -f "$KUBECONFIG" ]; then
  echo "Erreur : $KUBECONFIG introuvable. Lance d'abord l'etape 4 :" >&2
  echo "  cd ansible && ansible-playbook site.yml --tags cluster,ingress --ask-vault-pass" >&2
  exit 1
fi

ARGOCD_HOST=$(awk -F'"' '/^argocd_hostname:/ {print $2}' "$VARS")
MONITORING_HOST=$(awk -F'"' '/^monitoring_hostname:/ {print $2}' "$VARS")

NLB=$(kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "$NLB" ]; then
  echo "Erreur : le NLB Traefik n'a pas encore de hostname (ou Traefik n'est pas installe)." >&2
  echo "Verifie : kubectl -n traefik get svc traefik" >&2
  exit 1
fi

echo "Enregistrements DNS a creer chez ton registrar (type CNAME, pas d'IP) :"
echo
printf "  %-8s %-12s %s\n" "TYPE" "NOM" "VALEUR"
printf "  %-8s %-12s %s\n" "CNAME" "${ARGOCD_HOST%%.*}" "$NLB"
printf "  %-8s %-12s %s\n" "CNAME" "${MONITORING_HOST%%.*}" "$NLB"
echo
echo "Noms complets : $ARGOCD_HOST et $MONITORING_HOST"
echo "(Le champ 'nom' est parfois le nom complet, selon le registrar.)"
echo "(Cloudflare : proxy sur 'DNS only', nuage gris.)"
echo
echo "Verifier la propagation :"
echo "  nslookup $ARGOCD_HOST"
echo "  nslookup $MONITORING_HOST"

if [[ "$ARGOCD_HOST" == *domain.com ]]; then
  echo
  echo "ATTENTION : le domaine est toujours 'domain.com'. Lance d'abord :" >&2
  echo "  ./scripts/set-domain.sh mondomaine.fr" >&2
fi
