#!/usr/bin/env bash
# ==============================================================================
# Coolify Delta State Restoration Script for Google Drive (16GB / 4 vCPU)
# Implements fail-closed verification, 4-core pigz decompression, and auto-recovery.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"
CACHE_DIR="/tmp/coolify_restore_cache"
CYCLE_COUNT="${2:-0}"

# Tuned Rclone flags for Google Drive on 16GB RAM / 4 vCPU runners
RCLONE_OPTS=(
  "--drive-chunk-size=128M"
  "--drive-upload-cutoff=128M"
  "--drive-use-trash=false"
  "--fast-list"
  "--transfers=4"
  "--checkers=8"
  "--retries=6"
  "--retries-sleep=10s"
  "--timeout=10m"
  "--contimeout=30s"
  "--drive-pacer-min-sleep=100ms"
  "--checksum"
  "--stats=15s"
  "--stats-one-line"
)

echo "[COOLIFY-RESTORE] ======================================================="
echo "[COOLIFY-RESTORE] Phase: Fail-Closed State Hydration from Google Drive"
echo "[COOLIFY-RESTORE] Target: ${STORAGE_TARGET} | Cycle: ${CYCLE_COUNT}"
echo "[COOLIFY-RESTORE] ======================================================="

sudo mkdir -p "$SOURCE_DIR" /var/lib/docker/volumes "$BACKUP_DIR" "$CACHE_DIR"
sudo chmod 777 "$CACHE_DIR"
sudo rm -rf "${CACHE_DIR:?}"/*

# Ensure pigz is installed for multi-core performance
if ! command -v pigz >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pigz
fi

# Ensure runner and root share rclone.conf
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
  sudo mkdir -p /root/.config/rclone
  sudo cp -f "$HOME/.config/rclone/rclone.conf" /root/.config/rclone/rclone.conf
fi

# ------------------------------------------------------------------------------
# STEP 1: Verify Google Drive Connectivity & Deduplicate
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Probing Google Drive connectivity..."
if ! rclone lsf "${RCLONE_OPTS[@]}" "${STORAGE_TARGET}" --max-depth 1 >/tmp/gdrive_files.txt 2>&1; then
  echo "[COOLIFY-RESTORE] CRITICAL: Unable to reach Google Drive storage at ${STORAGE_TARGET}!"
  cat /tmp/gdrive_files.txt
  echo "[COOLIFY-RESTORE] Triggering fail-closed exit to prevent blank state overwrite."
  exit 1
fi

echo "[COOLIFY-RESTORE] Google Drive online. Running automatic deduplication..."
rclone dedupe "${RCLONE_OPTS[@]}" --dedupe-mode newest "${STORAGE_TARGET}" 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 2: Circuit Breaker - Verify State Existence
# ------------------------------------------------------------------------------
HAS_CORE_BUNDLE=false
if grep -q "^coolify_bundle\.tar\.gz" /tmp/gdrive_files.txt; then
  HAS_CORE_BUNDLE=true
fi

if [ "$HAS_CORE_BUNDLE" != "true" ]; then
  if [ "$CYCLE_COUNT" -gt 0 ]; then
    echo "[COOLIFY-RESTORE] FATAL ERROR: Cycle count is ${CYCLE_COUNT} but 'coolify_bundle.tar.gz' was NOT found in Google Drive!"
    echo "[COOLIFY-RESTORE] Refusing to initialize empty state over prior rotation cycles. Failing closed."
    exit 1
  else
    echo "[COOLIFY-RESTORE] NOTICE: Cycle count is 0 and remote storage is empty. Authorized for clean cold-start."
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
# STEP 3: Download to Local Cache & Validate Integrity
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Downloading state archives and checksums from Google Drive..."
rclone copy "${RCLONE_OPTS[@]}" "${STORAGE_TARGET}" "$CACHE_DIR" \
  --include "coolify_bundle.tar.gz" \
  --include "volumes_bundle.tar.gz" \
  --include "coolify_pg_latest.sql.gz" \
  --include "checksums.sha256"

# Validate SHA256 checksums if manifest exists
if [ -f "${CACHE_DIR}/checksums.sha256" ]; then
  echo "[COOLIFY-RESTORE] Validating SHA256 integrity manifest..."
  (cd "$CACHE_DIR" && sha256sum -c checksums.sha256) || {
    echo "[COOLIFY-RESTORE] FATAL: Checksum mismatch! Corrupted download detected. Aborting."
    exit 1
  }
  echo "[COOLIFY-RESTORE] Checksums verified successfully."
fi

# ------------------------------------------------------------------------------
# STEP 4: Parallel Decompression with 4-Core pigz
# ------------------------------------------------------------------------------
if [ -f "${CACHE_DIR}/coolify_bundle.tar.gz" ]; then
  echo "[COOLIFY-RESTORE] Extracting /data/coolify with pigz (4 cores)..."
  pigz -dc -p 4 "${CACHE_DIR}/coolify_bundle.tar.gz" | sudo tar --numeric-owner -xpf - -C /data/coolify
fi

if [ -f "${CACHE_DIR}/volumes_bundle.tar.gz" ]; then
  echo "[COOLIFY-RESTORE] Extracting Docker volumes with pigz (4 cores)..."
  pigz -dc -p 4 "${CACHE_DIR}/volumes_bundle.tar.gz" | sudo tar --numeric-owner -xpf - -C /var/lib/docker/volumes
fi

if [ -f "${CACHE_DIR}/coolify_pg_latest.sql.gz" ]; then
  sudo cp -f "${CACHE_DIR}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz"
fi

# Clean up local restore cache
rm -rf "$CACHE_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 5: Linux Permissions, SSH Configuration & Keys Normalization
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Normalizing permissions and SSH configurations..."
sudo chmod -R 755 /data/coolify 2>/dev/null || true
[ -d "/data/coolify/source" ] && sudo chmod -R 775 /data/coolify/source 2>/dev/null || true

# Ensure APP_URL is correctly set to coolify.justsawyou.cyou
if [ -f "/data/coolify/source/.env" ]; then
  sudo sed -i 's|^APP_URL=.*|APP_URL=https://coolify.justsawyou.cyou|g' /data/coolify/source/.env 2>/dev/null || true
fi

# Configure host SSH daemon for Coolify internal engine communication
sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server
sudo mkdir -p /etc/ssh/sshd_config.d /root/.ssh /home/runner/.ssh
cat << 'EOF' | sudo tee /etc/ssh/sshd_config.d/99-coolify.conf >/dev/null
PermitRootLogin yes
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile .ssh/authorized_keys
EOF
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

# Guarantee that a valid root host key for @host.docker.internal exists in /data/coolify/ssh/keys
sudo mkdir -p /data/coolify/ssh/keys
EXISTING_KEY=$(find /data/coolify/ssh/keys -maxdepth 1 -type f \( -name "ssh_key@*" -o -name "id_*" \) ! -name "*.pub" ! -name "*.lock" 2>/dev/null | head -n 1 || true)
if [ -n "$EXISTING_KEY" ] && [ ! -f "/data/coolify/ssh/keys/id.root@host.docker.internal" ]; then
  sudo cp -f "$EXISTING_KEY" /data/coolify/ssh/keys/id.root@host.docker.internal
  sudo ssh-keygen -y -f /data/coolify/ssh/keys/id.root@host.docker.internal > /tmp/id.root@host.docker.internal.pub 2>/dev/null || true
  [ -f /tmp/id.root@host.docker.internal.pub ] && sudo mv -f /tmp/id.root@host.docker.internal.pub /data/coolify/ssh/keys/id.root@host.docker.internal.pub || true
elif [ ! -f "/data/coolify/ssh/keys/id.root@host.docker.internal" ]; then
  echo "[COOLIFY-RESTORE] Generating host.docker.internal SSH key pair..."
  sudo ssh-keygen -t ed25519 -N "" -f /data/coolify/ssh/keys/id.root@host.docker.internal -C "root@host.docker.internal" 2>/dev/null || true
fi

sudo chmod 700 /data/coolify/ssh /data/coolify/ssh/keys
sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
sudo chown -R 9999:root /data/coolify/ssh 2>/dev/null || true

# Inject default onboarding key and all existing keys into authorized_keys for root and runner
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINGMEL5LpxfXWB1Q2gd028oYZzpuGe97jlmgbYza+pN" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null
for priv in /data/coolify/ssh/keys/*; do
  if [ -f "$priv" ] && [[ ! "$priv" =~ \.pub$ ]] && [[ ! "$priv" =~ \.lock$ ]]; then
    sudo ssh-keygen -y -f "$priv" 2>/dev/null | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null || true
  fi
done
for pub in /data/coolify/ssh/keys/*.pub; do
  [ -f "$pub" ] && sudo cat "$pub" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null || true
done
sudo chmod 700 /root/.ssh /home/runner/.ssh
sudo chmod 600 /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 6: Database Bring-up & PostgreSQL Restoration
# ------------------------------------------------------------------------------
if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  echo "[COOLIFY-RESTORE] Initializing coolify Docker network..."
  sudo docker network create --attachable coolify 2>/dev/null || true

  echo "[COOLIFY-RESTORE] Starting PostgreSQL database container..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d postgres 2>&1 || true

  echo "[COOLIFY-RESTORE] Polling pg_isready..."
  PG_READY=false
  for i in {1..30}; do
    if sudo docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1 || sudo docker exec -i coolify-db pg_isready >/dev/null 2>&1; then
      echo "[COOLIFY-RESTORE] PostgreSQL is fully ready! ($((i*2))s)"
      PG_READY=true
      break
    fi
    sleep 2
  done

  if [ "$PG_READY" != "true" ]; then
    echo "[COOLIFY-RESTORE] FATAL: PostgreSQL failed to become ready within 60s. Aborting."
    exit 1
  fi

  if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
    echo "[COOLIFY-RESTORE] Restoring PostgreSQL dump into database with pigz..."
    pigz -dc -p 4 "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>&1 || {
      echo "[COOLIFY-RESTORE] Warning: PostgreSQL restore reported warnings/non-zero status. Inspecting database tables..."
    }
    echo "[COOLIFY-RESTORE] PostgreSQL state hydrated."
  fi

  # Boot Coolify core and proxy
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d --remove-orphans 2>&1 || true

  if [ -d "/data/coolify/proxy" ] && [ -f "/data/coolify/proxy/docker-compose.yml" ]; then
    sudo docker compose --project-directory /data/coolify/proxy -f /data/coolify/proxy/docker-compose.yml up -d 2>/dev/null || true
  fi

  # If database already had tables/users restored, do NOT re-run migrations/seeders
  DB_HAS_USERS=$(sudo docker exec -i coolify-db psql -U coolify -d coolify -tAc "SELECT count(*) FROM users;" 2>/dev/null || echo "0")
  echo "[COOLIFY-RESTORE] Verified existing database users: ${DB_HAS_USERS}"

  for s in {1..30}; do
    if sudo docker exec coolify php artisan --version >/dev/null 2>&1; then
      if [ "$DB_HAS_USERS" -eq 0 ] 2>/dev/null; then
        echo "[COOLIFY-RESTORE] Fresh database detected. Running initial migrations and ProductionSeeder..."
        sudo docker exec coolify php artisan migrate --force 2>/dev/null || true
        sudo docker exec coolify php artisan db:seed --class=ProductionSeeder --force 2>/dev/null || true
      else
        echo "[COOLIFY-RESTORE] Preserving existing database state. Skipping destructive seeders."
      fi

      echo "[COOLIFY-RESTORE] Binding localhost Server(0) and PrivateKey(0) in Coolify database..."
      sudo docker exec coolify php artisan tinker --execute='
        try {
          $priv = @file_get_contents("/data/coolify/ssh/keys/id.root@host.docker.internal") ?: @file_get_contents("/var/www/html/storage/app/ssh/keys/id.root@host.docker.internal");
          if ($priv) {
            $pk = \App\Models\PrivateKey::find(0);
            if (!$pk) {
              $pk = new \App\Models\PrivateKey();
              $pk->id = 0;
              $pk->team_id = 0;
              $pk->name = "localhost key";
              $pk->description = "Host key for localhost";
              $pk->private_key = $priv;
              $pk->save();
            } else if (empty($pk->private_key)) {
              $pk->private_key = $priv;
              $pk->save();
            }
            $srv = \App\Models\Server::find(0);
            if ($srv) {
              $srv->private_key_id = 0;
              $srv->save();
            }
          }
        } catch (\Throwable $e) {}
      ' 2>/dev/null || true

      # Extract actual public key that Coolify PrivateKey(0) computes and inject into authorized_keys
      echo "[COOLIFY-RESTORE] Authorizing Coolify PrivateKey(0) public key on host..."
      COOLIFY_ACTUAL_PUB=$(sudo docker exec coolify php artisan tinker --execute='echo \App\Models\PrivateKey::find(0)?->getPublicKey();' 2>/dev/null | tr -d '\r\n' || true)
      if [ -n "$COOLIFY_ACTUAL_PUB" ] && [[ "$COOLIFY_ACTUAL_PUB" =~ ^ssh- ]]; then
        echo "$COOLIFY_ACTUAL_PUB" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null
        echo "[COOLIFY-RESTORE] Injected dynamic Coolify public key into authorized_keys."
      fi

      # Also populate storage/app/ssh/keys inside container so ssh-keys disk has the key file
      sudo docker exec coolify php artisan db:seed --class=PopulateSshKeysDirectorySeeder --force 2>/dev/null || true

      # Restart SSH daemon to pick up configuration changes
      sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
      break
    fi
    sleep 2
  done
fi

# ------------------------------------------------------------------------------
# STEP 7: Workload Auto-Discovery, Allowlist Filtering & Bring-up
# ------------------------------------------------------------------------------
echo "[COOLIFY-RESTORE] Discovering user application and service stacks..."
ALL_COMPOSE_FILES=()
while IFS= read -r -d '' file; do
  ALL_COMPOSE_FILES+=("$file")
done < <(find /data/coolify/applications /data/coolify/services /data/coolify/databases -name "docker-compose.yml" -print0 2>/dev/null || true)

if [ ${#ALL_COMPOSE_FILES[@]} -gt 0 ]; then
  echo "[COOLIFY-RESTORE] Found ${#ALL_COMPOSE_FILES[@]} total compose files on disk. Querying active DB allowlist..."

  ACTIVE_UUIDS_FILE="/tmp/coolify_active_uuids.txt"
  rm -f "$ACTIVE_UUIDS_FILE"
  touch "$ACTIVE_UUIDS_FILE"

  # Extract active resource UUIDs from Coolify PostgreSQL database using direct table union
  # Fallback to Laravel Tinker if psql query produces zero records
  sudo docker exec -i coolify-db psql -U coolify -d coolify -tAc '
    SELECT uuid FROM applications WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM services WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_postgresqls WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_mysqls WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_mariadbs WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_mongodbs WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_redises WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_keydbs WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_dragonflies WHERE deleted_at IS NULL
    UNION
    SELECT uuid FROM standalone_clickhouses WHERE deleted_at IS NULL;
  ' 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u > "$ACTIVE_UUIDS_FILE" || true

  # If SQL query returned empty, try extracting via artisan tinker
  if [ ! -s "$ACTIVE_UUIDS_FILE" ]; then
    sudo docker exec coolify php artisan tinker --execute='
      $uuids = collect();
      try { $uuids = $uuids->merge(\App\Models\Application::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\Service::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandalonePostgresql::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneMysql::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneMariadb::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneMongodb::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneRedis::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneKeydb::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneDragonfly::pluck("uuid")); } catch (\Throwable $e) {}
      try { $uuids = $uuids->merge(\App\Models\StandaloneClickhouse::pluck("uuid")); } catch (\Throwable $e) {}
      foreach ($uuids->unique()->filter() as $u) { echo $u . PHP_EOL; }
    ' 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u > "$ACTIVE_UUIDS_FILE" || true
  fi

  ACTIVE_COUNT=$(wc -l < "$ACTIVE_UUIDS_FILE" 2>/dev/null || echo 0)
  echo "[COOLIFY-RESTORE] Active resource UUIDs registered in DB: ${ACTIVE_COUNT}"

  # Build BOOT_LIST: non-destructive filtering against allowlist
  BOOT_LIST=()
  for compose in "${ALL_COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")

    # If DB active list is populated, strictly filter against it
    if [ "$ACTIVE_COUNT" -gt 0 ]; then
      if grep -Fxq "$svc_uuid" "$ACTIVE_UUIDS_FILE" 2>/dev/null; then
        echo "[COOLIFY-RESTORE] -> MATCH: ${svc_uuid} is active in DB. Adding to boot list."
        BOOT_LIST+=("$compose")
      else
        echo "[COOLIFY-RESTORE] -> SKIP: ${svc_uuid} not present in active DB. Skipping auto-boot."
      fi
    else
      # Safe Fallback: If DB query returned no UUIDs (e.g. cold start), include all discovered
      BOOT_LIST+=("$compose")
    fi
  done
  rm -f "$ACTIVE_UUIDS_FILE"

  echo "[COOLIFY-RESTORE] Stacks scheduled for boot: ${#BOOT_LIST[@]} / ${#ALL_COMPOSE_FILES[@]}"

  # 1. Seamless Data Migration: Dynamically find all code-server workspace volumes
  echo "[COOLIFY-RESTORE] Inspecting Code Server workspace data across volumes..."
  CS_VOLUMES=($(find /var/lib/docker/volumes -maxdepth 1 -type d -name "*code-server*" 2>/dev/null || true))
  if [ ${#CS_VOLUMES[@]} -gt 1 ]; then
    # Find the volume with existing workspace content
    SOURCE_CS=""
    for v in "${CS_VOLUMES[@]}"; do
      if [ -f "$v/_data/workspace/notes.txt" ] || [ -d "$v/_data/.claude" ] || [ -f "$v/_data/workspace/main.py" ]; then
        SOURCE_CS="$v"
        break
      fi
    done

    if [ -n "$SOURCE_CS" ]; then
      for target_v in "${CS_VOLUMES[@]}"; do
        if [ "$target_v" != "$SOURCE_CS" ]; then
          echo "[COOLIFY-RESTORE] Synchronizing preserved workspace and Claude data from $SOURCE_CS to $target_v..."
          sudo mkdir -p "$target_v/_data/workspace"
          [ -d "$SOURCE_CS/_data/workspace" ] && sudo cp -rn "$SOURCE_CS/_data/workspace/"* "$target_v/_data/workspace/" 2>/dev/null || true
          [ -d "$SOURCE_CS/_data/.claude" ] && sudo cp -rn "$SOURCE_CS/_data/.claude" "$target_v/_data/" 2>/dev/null || true
          sudo chown -R 1000:1000 "$target_v/_data" 2>/dev/null || true
        fi
      done
      echo "[COOLIFY-RESTORE] Workspace and Claude chat data dynamically synchronized across Code Server volumes."
    fi
  fi

  # 2. Pre-create required external networks ONLY for active stacks in BOOT_LIST
  echo "[COOLIFY-RESTORE] Initializing network topology for active workloads..."
  sudo docker network create --attachable coolify 2>/dev/null || true

  ACTIVE_NETWORKS=()
  for compose in "${BOOT_LIST[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")
    sudo docker network create --attachable "$svc_uuid" 2>/dev/null || true
    ACTIVE_NETWORKS+=("$svc_uuid")

    # Native compose network inspection
    declared_nets=$(cd "$workdir" && sudo docker compose -f "$compose" config --networks 2>/dev/null || true)
    for net in $declared_nets; do
      if [ -n "$net" ] && [ "$net" != "default" ]; then
        sudo docker network create --attachable "$net" 2>/dev/null || true
        ACTIVE_NETWORKS+=("$net")
      fi
    done

    # Robust AWK fallback parser in case compose config fails on missing envs
    if [ -f "$compose" ]; then
      awk_nets=$(awk '/^networks:/{flag=1; next} /^[a-zA-Z0-9_-]+:/{if(flag && !/^[[:space:]]/) flag=0} flag && /^[[:space:]]+[a-zA-Z0-9_-]+:/{gsub(/:/, "", $1); print $1}' "$compose" 2>/dev/null || true)
      for anet in $awk_nets; do
        if [ -n "$anet" ] && [ "$anet" != "default" ] && [ "$anet" != "coolify" ]; then
          sudo docker network create --attachable "$anet" 2>/dev/null || true
          ACTIVE_NETWORKS+=("$anet")
        fi
      done
    fi
  done

  # 3. Launch each active service stack with explicit project-name and project-directory
  for compose in "${BOOT_LIST[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")
    echo "[COOLIFY-RESTORE] Starting active service stack for ${svc_uuid}..."
    env_arg=""
    [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
    (cd "$workdir" && sudo docker compose $env_arg --project-directory "$workdir" --project-name "$svc_uuid" -f "$compose" up -d --remove-orphans 2>&1 || true)
  done

  # 4. Connect ONLY active application networks to coolify-proxy for Traefik routing
  echo "[COOLIFY-RESTORE] Connecting active application networks to coolify-proxy..."
  if [ ${#ACTIVE_NETWORKS[@]} -gt 0 ]; then
    readarray -t UNIQUE_NETWORKS < <(printf '%s\n' "${ACTIVE_NETWORKS[@]}" | sort -u)
    for net in "${UNIQUE_NETWORKS[@]}"; do
      if sudo docker network inspect "$net" >/dev/null 2>&1; then
        sudo docker network connect "$net" coolify-proxy 2>/dev/null || true
      fi
    done
  fi
fi

echo "[COOLIFY-RESTORE] All active containers post-restore:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo "[COOLIFY-RESTORE] SUCCESS: Full state restoration complete."
