#!/bin/bash
# =============================================================================
# clever-deploy.sh — Déploiement automatisé Nextcloud sur Clever Cloud
#
# UI : utilise gum (https://github.com/charmbracelet/gum) si installé,
#      fallback sur des prompts shell standards sinon.
# =============================================================================

set -eE
set -o pipefail

# Couleurs ANSI (utilisées dans les fallbacks et messages courts)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# -----------------------------------------------------------------------------
# Détection de gum
# -----------------------------------------------------------------------------
HAS_GUM=false
command -v gum >/dev/null 2>&1 && HAS_GUM=true

# Messages diagnostics → stderr, pour rester visibles même quand un helper
# est appelé via $(...) (sinon stdout est capturé et le message disparaît).
info()    { echo -e "${BLUE}  ℹ  $1${NC}" >&2; }
success() { echo -e "${GREEN}  ✓  $1${NC}" >&2; }
warn()    { echo -e "${YELLOW}  ⚠  $1${NC}" >&2; }
error()   { echo -e "${RED}  ✗  $1${NC}"   >&2; exit 1; }

section() {
    echo ""
    if $HAS_GUM; then
        gum style --foreground 212 --bold "▶ $1"
    else
        echo -e "${BOLD}${BLUE}▶ $1${NC}"
    fi
    echo ""
}

# Saisie texte avec valeur par défaut.  Args: prompt, default_value, [placeholder]
prompt_input() {
    local prompt="$1" default="${2:-}" placeholder="${3:-}" v
    if $HAS_GUM; then
        v=$(gum input --prompt "▸ " --header "$prompt" --placeholder "$placeholder" --value "$default" --width 60)
    else
        echo -e "${CYAN}  ?  $prompt${NC}" >&2
        echo -ne "${BOLD}      → ${NC}" >&2
        read -r v
    fi
    echo "${v:-$default}"
}

# Saisie mot de passe (masquée).  Args: prompt
prompt_password() {
    local prompt="$1" v
    if $HAS_GUM; then
        v=$(gum input --password --prompt "▸ " --header "$prompt" --width 60)
    else
        echo -e "${CYAN}  ?  $prompt${NC}" >&2
        echo -ne "${BOLD}      → ${NC}" >&2
        read -s -r v
        echo "" >&2
    fi
    echo "$v"
}

# Saisie mot de passe avec confirmation et retry.  Args: prompt
# Boucle jusqu'à : non-vide ET concordant avec la confirmation.
# L'utilisateur peut toujours abandonner via Ctrl+C.
prompt_password_confirmed() {
    local prompt="$1" pwd1 pwd2
    while true; do
        pwd1=$(prompt_password "$prompt")
        if [ -z "$pwd1" ]; then
            warn "Mot de passe vide — réessayez (Ctrl+C pour annuler)."
            continue
        fi
        pwd2=$(prompt_password "Confirmez le mot de passe")
        if [ "$pwd1" != "$pwd2" ]; then
            warn "Les deux saisies ne correspondent pas — réessayez."
            continue
        fi
        echo "$pwd1"
        return 0
    done
}

# Confirmation oui/non.  Args: question.  Retour 0 = oui, 1 = non.
prompt_confirm() {
    local prompt="$1" v
    if $HAS_GUM; then
        gum confirm "$prompt"
    else
        echo -e "${CYAN}  ?  $prompt (o/N)${NC}" >&2
        echo -ne "${BOLD}      → ${NC}" >&2
        read -r v
        [[ "$v" =~ ^[oOyY]$ ]]
    fi
}

# Sélection dans une liste.  Args: header, default_code, [code1, label1, code2, label2 ...]
# Renvoie le code sélectionné sur stdout.
prompt_choose() {
    local header="$1" default_code="$2"; shift 2
    local codes=() labels=()
    while [ $# -ge 2 ]; do
        codes+=("$1"); labels+=("$2"); shift 2
    done

    if $HAS_GUM; then
        local default_label=""
        for i in "${!codes[@]}"; do
            [ "${codes[$i]}" = "$default_code" ] && default_label="${labels[$i]}"
        done
        local selected
        selected=$(gum choose --header "$header" --selected="$default_label" --cursor "▸ " --height 12 "${labels[@]}")
        for i in "${!labels[@]}"; do
            [ "${labels[$i]}" = "$selected" ] && { echo "${codes[$i]}"; return; }
        done
        echo "$default_code"
    else
        echo -e "${CYAN}  ?  $header${NC}" >&2
        local default_idx=1
        for i in "${!codes[@]}"; do
            local num=$((i + 1))
            if [ "${codes[$i]}" = "$default_code" ]; then
                echo -e "      ${BOLD}${GREEN}$num) ${labels[$i]} ★ conseillé${NC}" >&2
                default_idx=$num
            else
                echo -e "      ${DIM}$num) ${labels[$i]}${NC}" >&2
            fi
        done
        echo -ne "${BOLD}      → ${NC}" >&2
        local choice
        read -r choice
        choice="${choice:-$default_idx}"
        local idx=$((choice - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#codes[@]}" ]; then
            echo "${codes[$idx]}"
        else
            echo "$default_code"
        fi
    fi
}

# Encadré de titre / succès.  Args: text, fg_color (212=mauve, 46=vert, 196=rouge)
banner() {
    local text="$1" color="${2:-212}"
    if $HAS_GUM; then
        gum style --border double --align center --width 50 --margin "1 2" --padding "1 4" \
            --foreground "$color" --border-foreground "$color" "$text"
    else
        local c="$BLUE"
        [ "$color" = "46"  ] && c="$GREEN"
        [ "$color" = "196" ] && c="$RED"
        echo ""
        echo -e "${BOLD}${c}╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${c}║  $(printf '%-40s' "$text")║${NC}"
        echo -e "${BOLD}${c}╚══════════════════════════════════════════╝${NC}"
    fi
}

# Spinner pour commandes courtes silencieuses.  Args: title, then command...
spin() {
    local title="$1"; shift
    if $HAS_GUM; then
        gum spin --spinner dot --title "$title" -- "$@"
    else
        echo -e "${DIM}  ⋯  $title${NC}"
        "$@"
    fi
}

extract_env() {
    echo "$2" | grep -E "^(export )?$1=" | sed -E "s/^(export )?$1=//" \
        | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d $'\r' | tr -d ';'
}

# Récupère le realId d'un addon (format postgresql_xxx / redis_xxx)
# Nécessaire pour clever ng link — différent du addon_id (format addon_xxx)
get_real_id() {
    local addon_id="$1"
    local api_base
    if [ -n "$ORG_INPUT" ]; then
        api_base="https://api.clever-cloud.com/v2/organisations/${ORG_INPUT}/addons"
    else
        api_base="https://api.clever-cloud.com/v2/self/addons"
    fi
    clever curl "${api_base}/${addon_id}" 2>/dev/null | tail -1 \
        | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('realId',''))" 2>/dev/null \
        || true
}

# -----------------------------------------------------------------------------
# Nettoyage automatique en cas d'erreur ou d'interruption (Ctrl+C)
# -----------------------------------------------------------------------------
CLEANED_UP=false
cleanup_resources() {
    [ "$CLEANED_UP" = "true" ] && return
    CLEANED_UP=true
    # Network Group en premier (avant les addons)
    if [ "$ENABLE_NGP" = "true" ]; then
        [ -n "$NGP_NAME_DB" ]    && echo "y" | clever ng delete "$NGP_NAME_DB"    $ORG_FLAG 2>/dev/null || true
        [ -n "$NGP_NAME_CACHE" ] && echo "y" | clever ng delete "$NGP_NAME_CACHE" $ORG_FLAG 2>/dev/null || true
    fi
    [ -n "$CELLAR_ADDON_NAME" ] && clever addon delete "$CELLAR_ADDON_NAME" --yes 2>/dev/null || true
    [ -n "$REDIS_ADDON_NAME" ]  && clever addon delete "$REDIS_ADDON_NAME"  --yes 2>/dev/null || true
    [ -n "$PG_ADDON_NAME" ]     && clever addon delete "$PG_ADDON_NAME"     --yes 2>/dev/null || true
    [ -n "$APP_NAME" ]          && clever delete --app "$APP_NAME" --yes 2>/dev/null || true
    git remote remove clever 2>/dev/null || true
    rm -f .clever.json
}

on_error() {
    local exit_code=$?
    trap - ERR INT TERM
    echo ""
    warn "Erreur détectée — nettoyage en cours..."
    cleanup_resources
    warn "Nettoyage terminé."
    exit "$exit_code"
}

on_interrupt() {
    trap - ERR INT TERM
    echo ""
    warn "Interruption (Ctrl+C) — nettoyage en cours..."
    cleanup_resources
    warn "Nettoyage terminé."
    exit 130
}

trap on_error ERR
trap on_interrupt INT TERM

# =============================================================================
# PRÉREQUIS
# =============================================================================
banner "Nextcloud — Déploiement Clever Cloud" 212

if ! $HAS_GUM; then
    echo -e "  ${DIM}Astuce : installez gum pour une UI plus riche — https://github.com/charmbracelet/gum${NC}"
    echo ""
fi

section "Vérification des prérequis"
command -v clever  >/dev/null 2>&1 || error "clever-tools non installé : npm install -g clever-tools"
command -v git     >/dev/null 2>&1 || error "git non installé."
command -v python3 >/dev/null 2>&1 || error "python3 non installé."
clever profile >/dev/null 2>&1     || error "Non connecté. Lancez : clever login"
git rev-parse --git-dir >/dev/null 2>&1 || error "Lancez ce script depuis la racine du repo git."
success "Prérequis OK."

# =============================================================================
# CONFIGURATION GÉNÉRALE
# =============================================================================
section "Configuration générale"

APP_NAME=$(prompt_input "Nom de l'application" "nextcloud" "ex : nextcloud")
ALIAS="$APP_NAME"

ORG_INPUT=$(prompt_input "ID organisation Clever Cloud (vide = compte personnel)" "" "orga_xxxxxxxx")
if [ -n "$ORG_INPUT" ]; then
    ORG_FLAG="--org $ORG_INPUT"
    info "Organisation : $ORG_INPUT"
else
    ORG_FLAG=""
    info "Compte personnel sélectionné."
fi

NEXTCLOUD_DOMAIN=$(prompt_input "Domaine public (vide = cleverapps.io auto)" "" "cloud.exemple.fr")
DOMAIN_AUTO=false
[ -z "$NEXTCLOUD_DOMAIN" ] && DOMAIN_AUTO=true && info "Domaine automatique cleverapps.io."

# Région
REGION=$(prompt_choose "Région de déploiement" "par" \
    "par" "Paris       (par)  — Europe, France" \
    "rbx" "Roubaix     (rbx)  — Europe, France" \
    "scw" "Scaleway    (scw)  — Europe, France" \
    "ldn" "Londres     (ldn)  — Europe, Royaume-Uni" \
    "wsw" "Warsaw      (wsw)  — Europe, Pologne" \
    "mtl" "Montréal    (mtl)  — Amérique du Nord" \
    "sgp" "Singapour   (sgp)  — Asie-Pacifique" \
    "syd" "Sydney      (syd)  — Asie-Pacifique")
info "Région : $REGION"

# =============================================================================
# DIMENSIONNEMENT — Application PHP
# =============================================================================
section "Dimensionnement — Application PHP"

PHP_PLAN=$(prompt_choose "Plan de l'application PHP" "S" \
    "nano" "nano  —  582 MB RAM, 1 vCPU      (test / dev)" \
    "XS"   "XS    —  1.1 GB RAM, 1 vCPU      (solo, 1-3 utilisateurs)" \
    "S"    "S     —  2 GB RAM,   2 vCPUs     (petite équipe, 5-10)" \
    "M"    "M     —  4 GB RAM,   4 vCPUs     (équipe standard, 10-30)" \
    "L"    "L     —  8 GB RAM,   6 vCPUs     (usage intensif, 30-100)" \
    "XL"   "XL    —  16 GB RAM,  8 vCPUs     (grande équipe, 100+)")
info "Plan PHP : $PHP_PLAN"

# =============================================================================
# DIMENSIONNEMENT — PostgreSQL
# =============================================================================
section "Dimensionnement — Base de données PostgreSQL"

PG_PLAN=$(prompt_choose "Plan PostgreSQL" "xs_sml" \
    "xxs_sml" "xxs_sml  —  1 vCPU,  512 MB RAM,  1 GB  BDD  (solo / test)" \
    "xs_sml"  "xs_sml   —  1 vCPU,  1 GB RAM,    5 GB  BDD  (petite équipe, 5-10)" \
    "s_sml"   "s_sml    —  2 vCPUs, 2 GB RAM,   10 GB  BDD  (équipe standard, 10-30)" \
    "m_sml"   "m_sml    —  4 vCPUs, 4 GB RAM,   20 GB  BDD  (grande équipe, 30+)")
info "Plan PostgreSQL : $PG_PLAN"

PG_VERSION=$(prompt_choose "Version PostgreSQL" "18" \
    "18" "18  —  recommandée par Nextcloud" \
    "17" "17  —  défaut Clever Cloud" \
    "16" "16  —  version stable précédente" \
    "15" "15  —  ancienne version")
info "Version PostgreSQL : $PG_VERSION"

# =============================================================================
# DIMENSIONNEMENT — Redis
# =============================================================================
section "Dimensionnement — Cache Redis"

REDIS_PLAN=$(prompt_choose "Plan Redis" "m_mono" \
    "s_mono"  "s_mono   —  1 vCPU, 128 MB  (solo / petite équipe)" \
    "m_mono"  "m_mono   —  1 vCPU, 256 MB  (équipe standard)" \
    "l_mono"  "l_mono   —  1 vCPU, 512 MB  (usage intensif)" \
    "xl_mono" "xl_mono  —  1 vCPU, 1 GB    (grande équipe)")
info "Plan Redis : $REDIS_PLAN"

# =============================================================================
# RÉSEAU — Network Groups WireGuard (optionnel)
# =============================================================================
section "Réseau — Network Groups WireGuard (optionnel)"
echo -e "  ${DIM}Crée deux tunnels WireGuard distincts : app↔PostgreSQL et app↔Redis.${NC}"
echo -e "  ${DIM}PostgreSQL et Redis ne peuvent pas se joindre (least-privilege).${NC}"
echo -e "  ${DIM}Les hostnames publics restent actifs — aucun impact sur l'installation.${NC}"
echo ""
ENABLE_NGP=false
NGP_NAME_DB=""
NGP_NAME_CACHE=""
if prompt_confirm "Activer les Network Groups ?"; then
    ENABLE_NGP=true
    NGP_NAME_DB="${APP_NAME}-db-network"
    NGP_NAME_CACHE="${APP_NAME}-cache-network"
    info "2 Network Groups activés : '${NGP_NAME_DB}' et '${NGP_NAME_CACHE}'."
else
    info "Network Groups désactivés."
fi

# =============================================================================
# COMPTE ADMINISTRATEUR
# =============================================================================
section "Compte administrateur Nextcloud"

NEXTCLOUD_ADMIN_USER=$(prompt_input "Nom d'utilisateur admin" "admin" "admin")

NEXTCLOUD_ADMIN_PASSWORD=$(prompt_password_confirmed "Mot de passe admin")

# =============================================================================
# RÉSUMÉ
# =============================================================================
section "Résumé"
NGP_LINE="désactivés"
[ "$ENABLE_NGP" = "true" ] && NGP_LINE="activés — PG et Redis isolés l'un de l'autre"

if $HAS_GUM; then
    gum style --border rounded --padding "1 2" --margin "0 2" --border-foreground 212 \
"$(printf 'Application      %s — région %s\nDomaine          %s\nPHP              %s\nPostgreSQL       %s — version %s\nRedis            %s\nNetwork Groups   %s\nAdmin            %s' \
        "$APP_NAME" "$REGION" \
        "${NEXTCLOUD_DOMAIN:-cleverapps.io automatique}" \
        "$PHP_PLAN" \
        "$PG_PLAN" "$PG_VERSION" \
        "$REDIS_PLAN" \
        "$NGP_LINE" \
        "$NEXTCLOUD_ADMIN_USER")"
else
    echo -e "  ${DIM}Application${NC}   ${BOLD}$APP_NAME${NC} — région ${BOLD}$REGION${NC}"
    echo -e "  ${DIM}Domaine    ${NC}   ${BOLD}${NEXTCLOUD_DOMAIN:-cleverapps.io automatique}${NC}"
    echo -e "  ${DIM}PHP        ${NC}   ${BOLD}$PHP_PLAN${NC}"
    echo -e "  ${DIM}PostgreSQL ${NC}   ${BOLD}$PG_PLAN${NC} — version ${BOLD}$PG_VERSION${NC}"
    echo -e "  ${DIM}Redis      ${NC}   ${BOLD}$REDIS_PLAN${NC}"
    echo -e "  ${DIM}Network Groups${NC} ${BOLD}$NGP_LINE${NC}"
    echo -e "  ${DIM}Admin      ${NC}   ${BOLD}$NEXTCLOUD_ADMIN_USER${NC}"
fi
echo ""
prompt_confirm "Confirmer le déploiement ?" || { trap - ERR INT TERM; warn "Annulé."; exit 0; }

# =============================================================================
# CRÉATION DES RESSOURCES
# =============================================================================
section "Création de l'application PHP"
clever create --type php --region "$REGION" $ORG_FLAG --alias "$ALIAS" "$APP_NAME"

# Récupère l'APP_ID depuis .clever.json (nécessaire pour le sizing et le NGP)
APP_ID=$(python3 -c "import json; apps=json.load(open('.clever.json'))['apps']; print(next(a['app_id'] for a in apps if a['alias']=='$ALIAS'))" 2>/dev/null)

# Apply instance sizing: runtime fixed à $PHP_PLAN, build M (separateBuild)
# (minFlavor=maxFlavor évite l'erreur silencieuse min>max quand $PHP_PLAN < S)
if [ -n "$APP_ID" ] && [ -n "$ORG_INPUT" ]; then
    clever curl -s -X PUT \
        -H "Content-Type: application/json" \
        -d "{\"minInstances\":1,\"maxInstances\":1,\"minFlavor\":\"$PHP_PLAN\",\"maxFlavor\":\"$PHP_PLAN\",\"homogeneous\":false,\"separateBuild\":true,\"buildFlavor\":\"M\"}" \
        "https://api.clever-cloud.com/v2/organisations/${ORG_INPUT}/applications/${APP_ID}" >/dev/null 2>&1
    success "Runtime: $PHP_PLAN | Build: M (dedicated)"
fi

if [ "$DOMAIN_AUTO" = "true" ]; then
    NEXTCLOUD_DOMAIN=$(clever domain --alias "$ALIAS" 2>/dev/null \
        | grep 'cleverapps.io' | awk '{print $1}' | tr -d '/' | head -n1)
    [ -z "$NEXTCLOUD_DOMAIN" ] && NEXTCLOUD_DOMAIN="${APP_NAME}.cleverapps.io"
fi

configure_php_env() {
    clever env set --alias "$ALIAS" CC_PHP_VERSION        8.2                    >/dev/null 2>&1
    clever env set --alias "$ALIAS" CC_PHP_MEMORY_LIMIT   512M                   >/dev/null 2>&1
    clever env set --alias "$ALIAS" CC_PHP_EXTENSIONS     apcu                   >/dev/null 2>&1
    clever env set --alias "$ALIAS" CC_WEBROOT            /                      >/dev/null 2>&1
    clever env set --alias "$ALIAS" CC_POST_BUILD_HOOK    "scripts/install.sh"   >/dev/null 2>&1
    clever env set --alias "$ALIAS" CC_PRE_RUN_HOOK       "scripts/run.sh"       >/dev/null 2>&1
    clever env set --alias "$ALIAS" CC_RUN_SUCCEEDED_HOOK "scripts/skeleton.sh"  >/dev/null 2>&1
}
if $HAS_GUM; then
    gum spin --spinner dot --title "Configuration des variables PHP..." -- bash -c "$(declare -f configure_php_env); ALIAS='$ALIAS' configure_php_env"
else
    configure_php_env
fi
success "Application PHP créée — domaine : $NEXTCLOUD_DOMAIN"

section "Création des addons"

# PostgreSQL
# On capture la sortie pour extraire l'ID (nécessaire pour le Network Group)
PG_ADDON_NAME="${APP_NAME}-pg"
PG_OUT=$(clever addon create postgresql-addon --plan "$PG_PLAN" --region "$REGION" \
    --addon-version "$PG_VERSION" \
    $ORG_FLAG --link "$ALIAS" "$PG_ADDON_NAME" --yes 2>&1)
PG_ADDON_ID=$(echo "$PG_OUT" | grep "^ID:" | awk '{print $2}' | head -n1)
success "PostgreSQL créé ($PG_PLAN, version $PG_VERSION)"

# Redis
REDIS_ADDON_NAME="${APP_NAME}-redis"
REDIS_OUT=$(clever addon create redis-addon --plan "$REDIS_PLAN" --region "$REGION" \
    $ORG_FLAG --link "$ALIAS" "$REDIS_ADDON_NAME" --yes 2>&1)
REDIS_ADDON_ID=$(echo "$REDIS_OUT" | grep "^ID:" | awk '{print $2}' | head -n1)
[ -z "$REDIS_ADDON_ID" ] && error "Impossible d'extraire l'ID Redis."
REDIS_ENV=$(clever addon env "$REDIS_ADDON_ID" $ORG_FLAG --format shell 2>&1)
REDIS_HOST_VAL=$(extract_env "REDIS_HOST"     "$REDIS_ENV")
REDIS_PORT_VAL=$(extract_env "REDIS_PORT"     "$REDIS_ENV" | tr -dc '0-9')
REDIS_PASS_VAL=$(extract_env "REDIS_PASSWORD" "$REDIS_ENV")
[ -z "$REDIS_HOST_VAL" ] && error "REDIS_HOST introuvable."
clever env set --alias "$ALIAS" REDIS_HOST     "$REDIS_HOST_VAL" >/dev/null 2>&1
clever env set --alias "$ALIAS" REDIS_PORT     "$REDIS_PORT_VAL" >/dev/null 2>&1
clever env set --alias "$ALIAS" REDIS_PASSWORD "$REDIS_PASS_VAL" >/dev/null 2>&1
success "Redis créé ($REDIS_PLAN)"

# Cellar S3
CELLAR_ADDON_NAME="${APP_NAME}-cellar"
CELLAR_OUT=$(clever addon create cellar-addon --plan s --region "$REGION" \
    $ORG_FLAG --link "$ALIAS" "$CELLAR_ADDON_NAME" --yes 2>&1)
CELLAR_ADDON_ID=$(echo "$CELLAR_OUT" | grep "^ID:" | awk '{print $2}' | head -n1)
[ -z "$CELLAR_ADDON_ID" ] && error "Impossible d'extraire l'ID Cellar."
CELLAR_BUCKET_SUFFIX=$(echo "$CELLAR_ADDON_ID" | sed "s/addon_//" | cut -c1-8)
CELLAR_BUCKET_NAME="${APP_NAME}-files-${CELLAR_BUCKET_SUFFIX}"
CELLAR_ENV=$(clever addon env "$CELLAR_ADDON_ID" $ORG_FLAG --format shell 2>&1)
CELLAR_KEY=$(extract_env    "CELLAR_ADDON_KEY_ID"     "$CELLAR_ENV")
CELLAR_SECRET=$(extract_env "CELLAR_ADDON_KEY_SECRET" "$CELLAR_ENV")
CELLAR_HOST=$(extract_env   "CELLAR_ADDON_HOST"       "$CELLAR_ENV")
[ -z "$CELLAR_KEY" ] && error "CELLAR_ADDON_KEY_ID introuvable."
clever env set --alias "$ALIAS" CELLAR_ADDON_KEY_ID     "$CELLAR_KEY"         >/dev/null 2>&1
clever env set --alias "$ALIAS" CELLAR_ADDON_KEY_SECRET "$CELLAR_SECRET"      >/dev/null 2>&1
clever env set --alias "$ALIAS" CELLAR_ADDON_HOST       "$CELLAR_HOST"        >/dev/null 2>&1
clever env set --alias "$ALIAS" CELLAR_BUCKET_NAME      "$CELLAR_BUCKET_NAME" >/dev/null 2>&1
success "Cellar S3 créé (stockage fichiers)"

# Variables Nextcloud
clever env set --alias "$ALIAS" NEXTCLOUD_DOMAIN         "$NEXTCLOUD_DOMAIN"         >/dev/null 2>&1
clever env set --alias "$ALIAS" NEXTCLOUD_ADMIN_USER     "$NEXTCLOUD_ADMIN_USER"     >/dev/null 2>&1
clever env set --alias "$ALIAS" NEXTCLOUD_ADMIN_PASSWORD "$NEXTCLOUD_ADMIN_PASSWORD" >/dev/null 2>&1
success "Variables Nextcloud configurées."

# Domaine personnalisé
if [ "$DOMAIN_AUTO" = "false" ] && [ -n "$NEXTCLOUD_DOMAIN" ]; then
    clever domain add --alias "$ALIAS" "$NEXTCLOUD_DOMAIN"
    success "Domaine $NEXTCLOUD_DOMAIN ajouté."
    warn "DNS : créez un CNAME $NEXTCLOUD_DOMAIN → domain.clever-cloud.com"
fi

# =============================================================================
# NETWORK GROUPS
# =============================================================================
if [ "$ENABLE_NGP" = "true" ]; then
    section "Création des Network Groups"

    # Activer la feature beta ng (idempotent)
    clever features enable ng >/dev/null 2>&1 || true

    # Récupérer les realIds des addons.
    # clever ng link attend le format realId (postgresql_xxx / redis_xxx),
    # pas le addon_id (addon_xxx) renvoyé par clever addon create.
    PG_REAL_ID=""
    REDIS_REAL_ID=""
    [ -n "$PG_ADDON_ID" ]    && PG_REAL_ID=$(get_real_id "$PG_ADDON_ID")
    [ -n "$REDIS_ADDON_ID" ] && REDIS_REAL_ID=$(get_real_id "$REDIS_ADDON_ID")

    NGP_OK=true
    [ -z "$APP_ID" ]        && warn "APP_ID introuvable — app non liée aux NGPs." && NGP_OK=false
    [ -z "$PG_REAL_ID" ]    && warn "realId PostgreSQL introuvable — PG non lié au NGP." && NGP_OK=false
    [ -z "$REDIS_REAL_ID" ] && warn "realId Redis introuvable — Redis non lié au NGP." && NGP_OK=false

    if [ "$NGP_OK" = "true" ]; then
        # NGP-db : app + PostgreSQL uniquement
        clever ng create "$NGP_NAME_DB" $ORG_FLAG 2>&1 | grep -E "✓|ERROR" || true
        clever ng link "$APP_ID"     "$NGP_NAME_DB" $ORG_FLAG 2>&1 | grep -E "✓|Member" || true
        clever ng link "$PG_REAL_ID" "$NGP_NAME_DB" $ORG_FLAG 2>&1 | grep -E "✓|Member" || true
        success "NGP db '${NGP_NAME_DB}' créé — app + PostgreSQL"

        # NGP-cache : app + Redis uniquement (PG ne peut pas joindre Redis)
        clever ng create "$NGP_NAME_CACHE" $ORG_FLAG 2>&1 | grep -E "✓|ERROR" || true
        clever ng link "$APP_ID"        "$NGP_NAME_CACHE" $ORG_FLAG 2>&1 | grep -E "✓|Member" || true
        clever ng link "$REDIS_REAL_ID" "$NGP_NAME_CACHE" $ORG_FLAG 2>&1 | grep -E "✓|Member" || true
        success "NGP cache '${NGP_NAME_CACHE}' créé — app + Redis"

        clever env set --alias "$ALIAS" CC_NGP_DB_NAME    "$NGP_NAME_DB"    >/dev/null 2>&1
        clever env set --alias "$ALIAS" CC_NGP_CACHE_NAME "$NGP_NAME_CACHE" >/dev/null 2>&1

        echo -e "  ${DIM}PostgreSQL et Redis sont dans des réseaux distincts — pas de communication possible entre eux${NC}"
        echo -e "  ${DIM}Tunnels WireGuard disponibles via DNS privés (*.cc-ng.cloud)${NC}"
        echo -e "  ${DIM}Les hostnames publics restent actifs — aucun impact sur le démarrage${NC}"
    else
        warn "Network Groups partiellement configurés — certains membres n'ont pas pu être liés."
    fi
fi

# =============================================================================
# DÉPLOIEMENT
# =============================================================================
section "Déploiement"
# S'assurer que les scripts sont exécutables dans git (nécessaire sur macOS/Windows)
git update-index --chmod=+x \
    scripts/run.sh scripts/install.sh scripts/skeleton.sh \
    scripts/cron.sh scripts/sync-apps.sh scripts/ensure-apps.sh 2>/dev/null || true
# Committer si des bits ont changé — sinon Clever Cloud clone un repo sans +x
if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "chore: marquer les scripts comme exécutables" --no-verify 2>/dev/null || true
fi
info "Envoi du code source..."
clever deploy --alias "$ALIAS" --force

trap - ERR INT TERM

# =============================================================================
# SUCCÈS
# =============================================================================
banner "Déploiement réussi !" 46

if $HAS_GUM; then
    NGP_INFO=""
    if [ "$ENABLE_NGP" = "true" ]; then
        NGP_INFO=$(printf '\nNGP db           clever ng get %s %s\nNGP cache        clever ng get %s %s' \
            "$NGP_NAME_DB" "$ORG_FLAG" "$NGP_NAME_CACHE" "$ORG_FLAG")
    fi
    gum style --border rounded --padding "1 2" --margin "0 2" --border-foreground 46 \
"$(printf 'URL              https://%s\nAdmin            %s\nLogs             clever logs --alias %s%s' \
        "$NEXTCLOUD_DOMAIN" "$NEXTCLOUD_ADMIN_USER" "$ALIAS" "$NGP_INFO")"
else
    echo -e "  ${DIM}URL    ${NC}  ${BOLD}${GREEN}https://$NEXTCLOUD_DOMAIN${NC}"
    echo -e "  ${DIM}Admin  ${NC}  ${BOLD}$NEXTCLOUD_ADMIN_USER${NC}"
    echo -e "  ${DIM}Logs   ${NC}  clever logs --alias $ALIAS"
    if [ "$ENABLE_NGP" = "true" ]; then
        echo -e "  ${DIM}NGP db   ${NC}  clever ng get $NGP_NAME_DB $ORG_FLAG"
        echo -e "  ${DIM}NGP cache${NC}  clever ng get $NGP_NAME_CACHE $ORG_FLAG"
    fi
fi
echo ""
warn "Premier démarrage : 2 à 5 minutes (installation Nextcloud)."
echo ""
