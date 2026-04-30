#!/bin/bash
# =============================================================================
# ensure-apps.sh — Réconciliation robuste des apps Nextcloud
#
# Source de vérité : PostgreSQL (tables oc_appconfig / oc_migrations)
# Cache fichiers   : S3 Cellar (custom_apps/)
# Fallback         : App Store Nextcloud (re-téléchargement si S3 vide)
#
# Séquence :
#   1. Pull custom_apps/ depuis S3 (cache rapide)
#   2. Restaurer les permissions +x sur les binaires (perdues par rclone)
#   3. Lister les apps "installed" en BDD mais absentes du filesystem
#   4. Réinstaller les manquantes depuis l'app store
#   5. Push vers S3 si des changements ont eu lieu
# =============================================================================
set -e

REAL_APP=$(cd "$(dirname "$0")/.." && pwd)
CUSTOM_APPS_DIR="$REAL_APP/custom_apps"
SYNC_SCRIPT="$REAL_APP/scripts/sync-apps.sh"
CHANGED=0

mkdir -p "$CUSTOM_APPS_DIR"

# -----------------------------------------------------------------------------
# Étape 1 : Pull S3 (cache) — échec toléré
# -----------------------------------------------------------------------------
echo "[INFO] ensure-apps: pull cache S3..."
if [ -f "$SYNC_SCRIPT" ]; then
    bash "$SYNC_SCRIPT" pull || echo "[WARN] ensure-apps: pull S3 échoué — fallback app store."
else
    echo "[WARN] ensure-apps: sync-apps.sh absent."
fi

# -----------------------------------------------------------------------------
# Étape 2 : Restaurer les permissions sur les binaires
# rclone ne préserve pas les bits d'exécution — les binaires embarqués
# (ex: coolwsd dans richdocumentscode) perdent leur +x après un sync S3.
# -----------------------------------------------------------------------------
echo "[INFO] ensure-apps: restauration des permissions..."
find "$CUSTOM_APPS_DIR" -type f \( -name "*.sh" -o -name "coolwsd*" -o -name "*.AppImage" \
    -o -name "coolforkit" -o -name "coolmount" -o -name "loolwsd*" \) \
    -exec chmod +x {} \; 2>/dev/null || true

# Binaires ELF génériques dans les apps (détection par magic bytes)
find "$CUSTOM_APPS_DIR" -type f -exec sh -c '
    for f; do
        head -c4 "$f" 2>/dev/null | grep -q "^.ELF" && chmod +x "$f"
    done
' _ {} + 2>/dev/null || true

# -----------------------------------------------------------------------------
# Étape 3 : Identifier les apps installées en BDD mais absentes du filesystem
# La table oc_migrations contient une entrée par app ayant des migrations
# appliquées — c'est le marqueur fiable d'une app installée.
# On compare avec ce qui est présent dans apps/ et custom_apps/.
# -----------------------------------------------------------------------------
echo "[INFO] ensure-apps: vérification de cohérence BDD ↔ filesystem..."

# Lister les apps installées en BDD via oc_appconfig (source de vérité Nextcloud).
# NC 33 utilise la colonne "appid" (pas "app"). On récupère TOUTES les apps
# connues (enabled=yes OU no) car même une app disabled doit être présente sur
# le filesystem pour pouvoir être ré-activée sans erreur.
DB_APPS=$(PGPASSWORD="$POSTGRESQL_ADDON_PASSWORD" psql \
    -h "$POSTGRESQL_ADDON_HOST" \
    -p "$POSTGRESQL_ADDON_PORT" \
    -U "$POSTGRESQL_ADDON_USER" \
    -d "$POSTGRESQL_ADDON_DB" \
    -tAc "SELECT DISTINCT appid FROM oc_appconfig
           WHERE configkey = 'enabled';" 2>/dev/null || true)

if [ -z "$DB_APPS" ]; then
    echo "[INFO] ensure-apps: aucune app en BDD ou BDD inaccessible — skip réconciliation."
else
    while IFS= read -r app; do
        app=$(echo "$app" | tr -d '[:space:]')
        [ -z "$app" ] && continue

        # Vérifier si l'app existe dans apps/ (bundled) ou custom_apps/
        if [ -d "$REAL_APP/apps/$app" ] || [ -d "$CUSTOM_APPS_DIR/$app" ]; then
            continue
        fi

        # App en BDD mais absente du filesystem — réinstaller
        echo "[WARN] ensure-apps: '$app' en BDD mais absente du filesystem — réinstallation..."
        if php "$REAL_APP/occ" app:install "$app" --keep-disabled --no-interaction 2>/dev/null; then
            echo "[OK] ensure-apps: '$app' réinstallée."
            CHANGED=1
        else
            # Tentative avec --force (app déjà enregistrée en BDD)
            if php "$REAL_APP/occ" app:install "$app" --force --keep-disabled --no-interaction 2>/dev/null; then
                echo "[OK] ensure-apps: '$app' réinstallée (force)."
                CHANGED=1
            else
                echo "[ERR] ensure-apps: impossible de réinstaller '$app'."
            fi
        fi
    done <<< "$DB_APPS"
fi

# -----------------------------------------------------------------------------
# Étape 4 : Restaurer les permissions (à nouveau, pour les apps fraîchement installées)
# -----------------------------------------------------------------------------
if [ "$CHANGED" -eq 1 ]; then
    find "$CUSTOM_APPS_DIR" -type f \( -name "*.sh" -o -name "coolwsd*" -o -name "*.AppImage" \
        -o -name "coolforkit" -o -name "coolmount" -o -name "loolwsd*" \) \
        -exec chmod +x {} \; 2>/dev/null || true
    find "$CUSTOM_APPS_DIR" -type f -exec sh -c '
        for f; do
            head -c4 "$f" 2>/dev/null | grep -q "^.ELF" && chmod +x "$f"
        done
    ' _ {} + 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Étape 5 : Push S3 si des apps ont été (ré)installées
# -----------------------------------------------------------------------------
if [ "$CHANGED" -eq 1 ]; then
    echo "[INFO] ensure-apps: nouvelles apps installées — mise à jour du cache S3..."
    if [ -f "$SYNC_SCRIPT" ]; then
        bash "$SYNC_SCRIPT" push || echo "[WARN] ensure-apps: push S3 échoué."
    fi
else
    echo "[INFO] ensure-apps: filesystem cohérent — cache S3 OK."
fi

echo "[OK] ensure-apps: réconciliation terminée."
