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
# ║    • Le Network Group WireGuard (si activé)                     ║
# ║    • L'application Clever Cloud et tous ses addons              ║
# ║    • Le bucket Cellar S3 et TOUS les fichiers uploadés          ║
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Détection de gum — UI riche si présent, fallback sinon
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

success() { echo -e "${GREEN}  ✓  $1${NC}" >&2; }
warn()    { echo -e "${YELLOW}  ⚠  $1${NC}" >&2; }
error()   { echo -e "${RED}  ✗  $1${NC}"   >&2; exit 1; }

# Bandeau de danger
danger_banner() {
    local text="$1"
    if $HAS_GUM; then
        gum style --border double --align center --width 60 --margin "1 2" --padding "1 4" \
            --foreground 196 --border-foreground 196 --bold "$text"
    else
        echo ""
        echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${RED}║           $(printf '%-55s' "$text")║${NC}"
        echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    fi
}

# Saisie texte avec gum si dispo
prompt_text() {
    local prompt="$1" placeholder="${2:-}" v
    if $HAS_GUM; then
        v=$(gum input --prompt "▸ " --header "$prompt" --placeholder "$placeholder" --width 60)
    else
        echo -ne "${BOLD}${RED}  $prompt : ${NC}" >&2
        read -r v
    fi
    echo "$v"
}

APP="$1"
ORG_INPUT="$2"

if [ -z "$APP" ]; then
    echo "Usage   : bash tools/clever-destroy.sh <app-name> [org-id]"
    echo "Exemple : bash tools/clever-destroy.sh nextcloud orga_xxx"
    exit 1
fi

[ -n "$ORG_INPUT" ] && ORG_FLAG="--org $ORG_INPUT" || ORG_FLAG=""

# Noms des NGPs possibles selon le mode choisi au déploiement
NGP_NAME_DB="${APP}-db-network"       # mode 2 (2 NGPs) ou mode 1 via fallback
NGP_NAME_CACHE="${APP}-cache-network" # mode 2 uniquement
NGP_NAME_LEGACY="${APP}-network"      # mode 1 (1 NGP, ancien nom)

# Vérifier quels NGPs existent pour cette app
NGP_DB_EXISTS=false
NGP_CACHE_EXISTS=false
NGP_LEGACY_EXISTS=false
if clever features enable ng >/dev/null 2>&1; then
    clever ng get "$NGP_NAME_DB"     $ORG_FLAG >/dev/null 2>&1 && NGP_DB_EXISTS=true     || true
    clever ng get "$NGP_NAME_CACHE"  $ORG_FLAG >/dev/null 2>&1 && NGP_CACHE_EXISTS=true  || true
    clever ng get "$NGP_NAME_LEGACY" $ORG_FLAG >/dev/null 2>&1 && NGP_LEGACY_EXISTS=true || true
fi
NGP_EXISTS=false
{ [ "$NGP_DB_EXISTS" = "true" ] || [ "$NGP_CACHE_EXISTS" = "true" ] || [ "$NGP_LEGACY_EXISTS" = "true" ]; } \
    && NGP_EXISTS=true

danger_banner "SUPPRESSION DÉFINITIVE ET IRRÉVERSIBLE"

# Construction de la liste des éléments à supprimer
TARGETS=()
[ "$NGP_DB_EXISTS"     = "true" ] && TARGETS+=("Network Group   : $NGP_NAME_DB  (app + PostgreSQL)")
[ "$NGP_CACHE_EXISTS"  = "true" ] && TARGETS+=("Network Group   : $NGP_NAME_CACHE  (app + Redis)")
[ "$NGP_LEGACY_EXISTS" = "true" ] && TARGETS+=("Network Group   : $NGP_NAME_LEGACY  (tunnel WireGuard)")
TARGETS+=("Application     : $APP")
TARGETS+=("PostgreSQL      : ${APP}-pg  (toutes les données)")
TARGETS+=("Redis           : ${APP}-redis")
TARGETS+=("Cellar S3       : ${APP}-cellar  (TOUS les fichiers uploadés)")
TARGETS+=("Local           : remote clever + .clever.json")

if $HAS_GUM; then
    LIST_BODY=$(printf 'Seront supprimés DÉFINITIVEMENT :\n\n')
    for t in "${TARGETS[@]}"; do LIST_BODY+="  • $t"$'\n'; done
    LIST_BODY+=$'\n  ⚠  IRRÉVERSIBLE. Aucune récupération possible.'
    gum style --border thick --padding "1 2" --margin "0 2" \
        --foreground 196 --border-foreground 196 "$LIST_BODY"
    if ! gum confirm "Continuer la suppression ?" --default=false \
        --selected.background "196" --selected.foreground "230"; then
        echo ""; warn "Annulé — aucune ressource supprimée."; exit 0
    fi
    CONFIRM=$(prompt_text "Tapez exactement 'supprimer' pour confirmer" "supprimer")
else
    echo ""
    echo -e "${RED}  Seront supprimés DÉFINITIVEMENT :${NC}"
    for t in "${TARGETS[@]}"; do echo -e "${RED}    • $t${NC}"; done
    echo ""
    echo -e "${BOLD}${RED}  ⚠  Cette opération est IRRÉVERSIBLE. Aucune récupération possible.${NC}"
    echo ""
    echo -ne "${BOLD}${RED}  Tapez exactement 'supprimer' pour confirmer : ${NC}"
    read -r CONFIRM
fi
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

# Network Groups — supprimés en premier pour libérer les membres proprement
if [ "$NGP_DB_EXISTS" = "true" ]; then
    echo "y" | clever ng delete "$NGP_NAME_DB" $ORG_FLAG 2>/dev/null \
        && success "Network Group $NGP_NAME_DB supprimé." \
        || warn "Network Group $NGP_NAME_DB : suppression échouée."
fi
if [ "$NGP_CACHE_EXISTS" = "true" ]; then
    echo "y" | clever ng delete "$NGP_NAME_CACHE" $ORG_FLAG 2>/dev/null \
        && success "Network Group $NGP_NAME_CACHE supprimé." \
        || warn "Network Group $NGP_NAME_CACHE : suppression échouée."
fi
if [ "$NGP_LEGACY_EXISTS" = "true" ]; then
    echo "y" | clever ng delete "$NGP_NAME_LEGACY" $ORG_FLAG 2>/dev/null \
        && success "Network Group $NGP_NAME_LEGACY supprimé." \
        || warn "Network Group $NGP_NAME_LEGACY : suppression échouée."
fi

clever addon delete "${APP}-cellar"   --yes 2>/dev/null && success "${APP}-cellar supprimé."   || warn "${APP}-cellar introuvable."
clever addon delete "${APP}-redis"    --yes 2>/dev/null && success "${APP}-redis supprimé."    || warn "${APP}-redis introuvable."
clever addon delete "${APP}-pg"       --yes 2>/dev/null && success "${APP}-pg supprimé."       || warn "${APP}-pg introuvable."
clever delete --app "$APP"            --yes 2>/dev/null && success "$APP supprimé."            || warn "$APP introuvable."
git remote remove clever 2>/dev/null  && success "Remote clever supprimé."                     || warn "Remote clever introuvable."
rm -f .clever.json && success ".clever.json supprimé."

echo ""
if $HAS_GUM; then
    gum style --foreground 46 --bold --margin "1 2" \
        "Nettoyage terminé. Relancez clever-deploy.sh pour une nouvelle installation."
else
    echo -e "${GREEN}  Nettoyage terminé. Relancez clever-deploy.sh pour une nouvelle installation.${NC}"
fi
echo ""
