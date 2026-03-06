#!/bin/bash
# =============================================================================
# clever-destroy.sh — Suppression COMPLÈTE d'une installation Nextcloud
# =============================================================================
#
# ╔══════════════════════════════════════════════════════════════════╗
# ║  ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗    ║
# ║  ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝    ║
# ║  ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗   ║
# ║  ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║   ║
# ║  ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝   ║
# ║   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝   ║
# ╠══════════════════════════════════════════════════════════════════╣
# ║  Ce script supprime DÉFINITIVEMENT et IRRÉVOCABLEMENT :         ║
# ║    • L'application Clever Cloud et tous ses addons              ║
# ║    • Le bucket Cellar S3 et TOUS les fichiers uploadés          ║
# ║    • Le Materia KV (cache et sessions)                          ║
# ║    • La base de données PostgreSQL et toutes ses données        ║
# ║                                                                  ║
# ║  AUCUNE RÉCUPÉRATION POSSIBLE après confirmation.               ║
# ║                                                                  ║
# ║  Usage réservé au développement et aux tests.                   ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Usage   : bash tools/clever-destroy.sh <app-name> [org-id]
# Exemple : bash tools/clever-destroy.sh nextcloud orga_xxx
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
success() { echo -e "${GREEN}  ✓  $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠  $1${NC}"; }
error()   { echo -e "${RED}  ✗  $1${NC}"; exit 1; }

APP="$1"
ORG_INPUT="$2"

if [ -z "$APP" ]; then
    echo "Usage   : bash tools/clever-destroy.sh <app-name> [org-id]"
    echo "Exemple : bash tools/clever-destroy.sh nextcloud orga_xxx"
    exit 1
fi

[ -n "$ORG_INPUT" ] && ORG_FLAG="--org $ORG_INPUT" || ORG_FLAG=""

echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║           SUPPRESSION DÉFINITIVE ET IRRÉVERSIBLE                 ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}  Seront supprimés DÉFINITIVEMENT :${NC}"
echo -e "${RED}    • Application  : $APP${NC}"
echo -e "${RED}    • PostgreSQL   : ${APP}-pg  (toutes les données)${NC}"
echo -e "${RED}    • Materia KV   : ${APP}-kv  (cache, sessions)${NC}"
echo -e "${RED}    • Cellar S3    : ${APP}-cellar  (TOUS les fichiers uploadés)${NC}"
echo -e "${RED}    • Local        : remote clever + .clever.json${NC}"
echo ""
echo -e "${BOLD}${RED}  ⚠  Cette opération est IRRÉVERSIBLE. Aucune récupération possible.${NC}"
echo ""
echo -ne "${BOLD}${RED}  Tapez exactement 'supprimer' pour confirmer : ${NC}"
read -r CONFIRM
[ "$CONFIRM" != "supprimer" ] && echo "" && warn "Annulé — aucune ressource supprimée." && exit 0
echo ""

extract_env() {
    echo "$2" | grep -E "^(export )?$1=" | sed -E "s/^(export )?$1=//" \
        | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d $'\r' | tr -d ';'
}

# Récupère les credentials depuis les vars d'env de l'app (pas l'addon)
APP_ENV=$(clever env --alias "$APP" $ORG_FLAG --format shell 2>/dev/null || true)

if [ -n "$APP_ENV" ]; then
    CELLAR_KEY=$(extract_env    "CELLAR_ADDON_KEY_ID"     "$APP_ENV")
    CELLAR_SECRET=$(extract_env "CELLAR_ADDON_KEY_SECRET" "$APP_ENV")
    CELLAR_HOST=$(extract_env   "CELLAR_ADDON_HOST"       "$APP_ENV")
    BUCKET_NAME=$(extract_env   "CELLAR_BUCKET_NAME"      "$APP_ENV")

    if [ -n "$CELLAR_KEY" ] && [ -n "$BUCKET_NAME" ]; then
        warn "Suppression du bucket S3 : $BUCKET_NAME..."
        DATE=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
        STRING_TO_SIGN="DELETE\n\n\n${DATE}\n/${BUCKET_NAME}/"
        SIGNATURE=$(echo -en "$STRING_TO_SIGN" | openssl sha1 -hmac "$CELLAR_SECRET" -binary | base64)
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            -H "Host: ${CELLAR_HOST}" \
            -H "Date: ${DATE}" \
            -H "Authorization: AWS ${CELLAR_KEY}:${SIGNATURE}" \
            "https://${CELLAR_HOST}/${BUCKET_NAME}/")
        if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
            success "Bucket $BUCKET_NAME supprimé (HTTP $HTTP_CODE)."
        else
            warn "Bucket $BUCKET_NAME : HTTP $HTTP_CODE (peut-être déjà vide ou inexistant)."
        fi
    else
        warn "Credentials Cellar introuvables — bucket non supprimé."
    fi
else
    warn "Impossible de lire les vars d'env — bucket non supprimé."
fi

clever addon delete "${APP}-cellar"   --yes 2>/dev/null && success "${APP}-cellar supprimé."   || warn "${APP}-cellar introuvable."
clever addon delete "${APP}-kv"       --yes 2>/dev/null && success "${APP}-kv supprimé."       || warn "${APP}-kv introuvable."
clever addon delete "${APP}-pg"       --yes 2>/dev/null && success "${APP}-pg supprimé."       || warn "${APP}-pg introuvable."
clever delete --app "$APP"            --yes 2>/dev/null && success "$APP supprimé."            || warn "$APP introuvable."
git remote remove clever 2>/dev/null  && success "Remote clever supprimé."                     || warn "Remote clever introuvable."
rm -f .clever.json && success ".clever.json supprimé."

echo ""
echo -e "${GREEN}  Nettoyage terminé. Relancez clever-deploy.sh pour une nouvelle installation.${NC}"
echo ""
