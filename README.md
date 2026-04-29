![Clever Cloud logo](github-assets/clever-cloud-logo.png)

# Nextcloud on Clever Cloud
[![Clever Cloud - PaaS](https://img.shields.io/badge/Clever%20Cloud-PaaS-orange)](https://clever-cloud.com)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-33-0082C9?logo=nextcloud)](https://nextcloud.com)
[![PHP](https://img.shields.io/badge/PHP-8.2-777BB4?logo=php)](https://www.php.net)

> **POC** — FS Bucket-free deployment of Nextcloud on Clever Cloud. No persistent local disk. Config is fully reconstructed from environment variables at every startup. User files live on Cellar S3. Secrets persist in PostgreSQL.

---

## Architecture

| Service | Role |
|---|---|
| **PHP / Apache** | Runs Nextcloud (PHP 8.2, APCu, OPcache) |
| **PostgreSQL** | Main database + secret persistence (`cc_nextcloud_secrets`) |
| **Redis** | Distributed cache — sessions, file locks, local memcache |
| **Cellar S3** | Objectstore for all user-uploaded files |

No FS Bucket. `config/`, `data/`, `custom_apps/` are ephemeral local directories recreated at each boot.

---

## How it works

### Secrets and config persistence

`maintenance:install` generates three instance-specific secrets (`instanceid`, `passwordsalt`, `secret`) that must remain stable across restarts — sessions, file shares, and encryption depend on them. After first install, `run.sh` extracts them and stores them in the PostgreSQL table `cc_nextcloud_secrets`. On every subsequent start, `config.php` is fully rebuilt from database secrets + environment variables.

### Boot sequence

| Hook | Script | What it does |
|---|---|---|
| `CC_POST_BUILD_HOOK` | `install.sh` | Downloads Nextcloud, handles step-by-step major upgrades |
| `CC_PRE_RUN_HOOK` | `run.sh` | Waits for PostgreSQL, installs (first boot) or upgrades, rebuilds `config.php`, pre-creates S3 bucket |
| `CC_RUN_SUCCEEDED_HOOK` | `skeleton.sh` | Uploads default skeleton files via WebDAV (first boot only) |

### Distributed locking

Redis is used for both `memcache.distributed` and `memcache.locking`. Sessions are stored in Redis so the app can scale horizontally without sticky sessions.

### Major version upgrades

Nextcloud blocks version skips across majors. `install.sh` compares the installed major (read from PostgreSQL) to the target and applies intermediate upgrades step by step (e.g. 30→31→32→33) before `run.sh` calls `occ upgrade`.

---

## Instance sizing

| | Size |
|---|---|
| **Build instance** | M (dedicated, speeds up `composer install` + NC download) |
| **Runtime min** | S |
| **Runtime max** | Chosen during `clever-deploy.sh` (vertical auto-scaling) |
| **Horizontal** | 1 instance (Redis sessions allow multi-instance if needed) |

---

## Repository structure

```
.
├── scripts/
│   ├── install.sh      CC_POST_BUILD_HOOK — downloads/upgrades Nextcloud
│   ├── run.sh          CC_PRE_RUN_HOOK    — rebuild config.php, install or upgrade
│   ├── skeleton.sh     CC_RUN_SUCCEEDED_HOOK — uploads example files (first boot)
│   ├── cron.sh         Called by Clever Cloud native cron every 5 min
│   └── sync-apps.sh    Syncs custom_apps/ to/from S3
├── clevercloud/
│   └── cron.json       Native CC cron — curls /cron.php every 5 min
├── deploy/
│   └── clever-deploy.sh   Interactive full provisioning script
└── tools/
    └── clever-destroy.sh  Full teardown (dev/test only)
```

---

## Deployment

### Prerequisites

Install clever-tools and log in to Clever Cloud:

```bash
npm install -g clever-tools
clever login
```

Then fork this repo and clone it locally:

```bash
git clone git@github.com:<you>/nextcloud-on-clevercloud.git
cd nextcloud-on-clevercloud
```

**Optional** — install [gum](https://github.com/charmbracelet/gum) for a richer interactive UI in the deploy/destroy scripts (styled prompts, arrow-key menus, password masking). The scripts auto-detect gum and fall back to plain prompts if it's missing.

```bash
# macOS
brew install gum
# Debian/Ubuntu
sudo apt install gum
# Fedora
sudo dnf install gum
```

### Automated (recommended)

```bash
bash deploy/clever-deploy.sh
```

The script provisions everything interactively:

1. Creates the PHP app with **build M / runtime S→XL** (vertical auto-scaling)
2. Creates PostgreSQL, Redis, and Cellar S3 add-ons and links them
3. Sets all required environment variables
4. Deploys — first startup takes **3–6 minutes** (Nextcloud install + DB seed)

### Teardown

```bash
bash tools/clever-destroy.sh nextcloud [orga_xxx]
```

Deletes the app, all add-ons, `.clever.json`, and the git remote. Requires typing `supprimer` to confirm.

### Manual setup

<details>
<summary>Step-by-step without the script</summary>

```bash
# 1. Create app
clever create --type php --region par --org <org_id> nextcloud

# 2. Set instance sizing (build M, runtime S→XL, 1 instance)
APP_ID=$(python3 -c "import json; print(json.load(open('.clever.json'))['apps'][0]['app_id'])")
clever curl -X PUT -H "Content-Type: application/json" \
  -d '{"minInstances":1,"maxInstances":1,"minFlavor":"S","maxFlavor":"XL","separateBuild":true,"buildFlavor":"M","homogeneous":false}' \
  "https://api.clever-cloud.com/v2/organisations/<org_id>/applications/$APP_ID"

# 3. Create add-ons
clever addon create postgresql-addon --plan xs_sml --addon-version 16 --link nextcloud nextcloud-pg
clever addon create redis-addon      --plan m_mono  --link nextcloud nextcloud-cache
clever addon create cellar-addon     --plan s       --link nextcloud nextcloud-cellar

# 4. Set environment variables
clever env set CC_PHP_VERSION         8.2
clever env set CC_PHP_MEMORY_LIMIT    512M
clever env set CC_PHP_EXTENSIONS      apcu
clever env set CC_WEBROOT             /
clever env set CC_POST_BUILD_HOOK     "scripts/install.sh"
clever env set CC_PRE_RUN_HOOK        "scripts/run.sh"
clever env set CC_RUN_SUCCEEDED_HOOK  "scripts/skeleton.sh"
clever env set ENABLE_REDIS           true
clever env set SESSION_TYPE           redis
clever env set NEXTCLOUD_DOMAIN       "<app-id>.cleverapps.io"
clever env set NEXTCLOUD_ADMIN_USER   "<admin_user>"
clever env set NEXTCLOUD_ADMIN_PASSWORD "<password>"
# Redis and Cellar credentials: get from `clever addon env <addon_id> --format shell`

# 5. Deploy
clever deploy
```

| Variable | Description | Source |
|---|---|---|
| `PORT` | HTTP port (default: 8080) | Injected by CC |
| `POSTGRESQL_ADDON_URI` | PostgreSQL connection string | Injected by CC |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` | Redis credentials | Set manually from addon env |
| `CELLAR_ADDON_HOST` / `CELLAR_ADDON_KEY_ID` / `CELLAR_ADDON_KEY_SECRET` | Cellar credentials | Set manually from addon env |
| `CELLAR_BUCKET_NAME` | S3 bucket name (auto-created) | Set manually |
| `NEXTCLOUD_DOMAIN` | Public hostname | Set manually |
| `NEXTCLOUD_ADMIN_USER` | Admin username | Set manually |
| `NEXTCLOUD_ADMIN_PASSWORD` | Admin password | Set manually |
| `NEXTCLOUD_VERSION` | Pin a specific NC version | Optional |
| `RUST_LOG` | Log level | Optional |

</details>

---

## Pin a Nextcloud version

```bash
clever env set NEXTCLOUD_VERSION 32.0.6 --alias nextcloud
clever deploy --alias nextcloud --force

# Back to latest:
clever env unset NEXTCLOUD_VERSION --alias nextcloud
```

---

## Known warnings

These appear in Administration → Overview. All are non-blocking.

| Warning | Explanation |
|---|---|
| **Code integrity** | Scripts and config files outside NC distribution — expected |
| **HSTS** | Managed by Clever Cloud's reverse proxy |
| **OPcache max_accelerated_files** | `.user.ini` applies to PHP-FPM only; NC's check uses PHP CLI |
| **APCu missing** | `CC_PHP_EXTENSIONS=apcu` loads for PHP-FPM; NC checks via CLI where it's unavailable |
| **AppAPI** | Optional Docker-based feature, unrelated to this deployment |

---

## Additional resources

- [Clever Cloud Documentation](https://www.clever-cloud.com/doc/)
- [Nextcloud Admin Documentation](https://docs.nextcloud.com/server/latest/admin_manual/)
- [Clever Tools CLI](https://github.com/CleverCloud/clever-tools)
- [Clever Cloud Status](https://status.clever-cloud.com/)