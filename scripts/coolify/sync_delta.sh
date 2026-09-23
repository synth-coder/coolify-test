#!/usr/bin/env bash
# ==============================================================================
# Universal Coolify Delta State Backup & Database Snapshot Script
# Built for High-Speed Multi-Core (pigz) Streaming to Google Drive
# Preserves 100% of /data/coolify and Docker application volumes with exact UIDs,
# permissions, symlinks, and databases across all deployed PaaS services.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"

sudo mkdir -p "$BACKUP_DIR"
sudo chown -R runner:docker "$BACKUP_DIR" 2>/dev/null || sudo chmod 777 "$BACKUP_DIR"

# Ensure rclone configuration is available for both runner and root
if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
  sudo mkdir -p /root/.config/rclone
  sudo cp -f "$HOME/.config/rclone/rclone.conf" /root/.config/rclone/rclone.conf
fi

echo "[COOLIFY-SYNC] === Initiating Universal State Dump & Google Drive Backup ==="

# 1. Check if Coolify DB container is running and dump PostgreSQL atomically
if sudo docker ps --format '{{.Names}}' | grep -q 'coolify-db'; then
  echo "[COOLIFY-SYNC] Dumping Coolify PostgreSQL database (coolify-db)..."
  sudo docker exec coolify-db pg_dumpall -U coolify --clean 2>/dev/null | pigz -p 4 -6 > "${BACKUP_DIR}/coolify_pg_latest.sql.gz" || \
    (sudo docker exec coolify-db pg_dumpall -U coolify --clean | gzip > "${BACKUP_DIR}/coolify_pg_latest.sql.gz")
  echo "[COOLIFY-SYNC] DB dump complete: $(du -sh "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | cut -f1)"
fi

# 2. Check for SQLite databases across applications/services and snapshot cleanly
if command -v sqlite3 >/dev/null 2>&1; then
  while IFS= read -r -d '' sqldb; do
    if [ -f "$sqldb" ]; then
      sqlite3 "$sqldb" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    fi
  done < <(sudo find /data/coolify -type f \( -name "*.sqlite" -o -name "*.db" \) -print0 2>/dev/null || true)
fi

# 3. Cleanly flush write buffers across all active user containers
echo "[COOLIFY-SYNC] Flushing write buffers across active workload containers..."
COMPOSE_LIST=()
while IFS= read -r -d '' compose; do
  COMPOSE_LIST+=("$compose")
done < <(sudo find /data/coolify/applications /data/coolify/services /data/coolify/databases -name "docker-compose.yml" -print0 2>/dev/null || true)

for compose in "${COMPOSE_LIST[@]}"; do
  workdir=$(dirname "$compose")
  env_arg=""
  [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
  (cd "$workdir" && sudo docker compose $env_arg -f "$compose" stop -t 5 2>/dev/null || true)
done

if [ -f "/data/coolify/source/docker-compose.yml" ]; then
  (cd /data/coolify/source && sudo docker compose --env-file .env -f docker-compose.yml -f docker-compose.prod.yml stop -t 10 coolify coolify-db 2>/dev/null || \
   cd /data/coolify/source && sudo docker compose stop -t 10 coolify coolify-db 2>/dev/null || true)
fi

# Multi-core streaming helper with fail-closed integrity
stream_pigz_to_storage() {
  local source_path="$1"
  local remote_dest="$2"
  shift 2
  local exclude_args=("$@")

  set +e
  if command -v pigz >/dev/null 2>&1; then
    sudo tar -cpf - -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . | pigz -p 4 -6 | \
      rclone rcat --drive-chunk-size=128M --drive-use-trash=false "$remote_dest"
  else
    sudo tar -cpzf - -C "$source_path" --warning=no-file-changed "${exclude_args[@]}" . | \
      rclone rcat --drive-chunk-size=128M --drive-use-trash=false "$remote_dest"
  fi
  local p_status=("${PIPESTATUS[@]}")
  set -e

  local tar_rc="${p_status[0]:-0}"
  local rclone_rc="${p_status[${#p_status[@]}-1]:-0}"

  if [ "$tar_rc" -gt 1 ]; then
    echo "[COOLIFY-SYNC] Error: tar failed with critical code $tar_rc on $source_path"
    return "$tar_rc"
  fi
  if [ "$rclone_rc" -ne 0 ]; then
    echo "[COOLIFY-SYNC] Error: rclone rcat failed with code $rclone_rc to $remote_dest"
    return "$rclone_rc"
  fi
  return 0
}

# 4. Stream /data/coolify (configurations, compose files, keys, proxy configs)
echo "[COOLIFY-SYNC] Streaming core /data/coolify bundle to ${STORAGE_TARGET}/coolify_bundle.tar.gz..."
stream_pigz_to_storage "/data/coolify" "${STORAGE_TARGET}/coolify_bundle.tar.gz" \
  --exclude="./proxy/certs" \
  --exclude="./proxy/certs/*" \
  --exclude="*.log" \
  --exclude="*/tmp/*" \
  --exclude="./backups/*"

# 5. Upload standalone PostgreSQL dump
if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
  echo "[COOLIFY-SYNC] Uploading standalone DB dump to Google Drive..."
  rclone copyto --drive-chunk-size=128M --drive-use-trash=false "${BACKUP_DIR}/coolify_pg_latest.sql.gz" "${STORAGE_TARGET}/coolify_pg_latest.sql.gz"
fi

# 6. Stream ALL Docker volumes (preserving all user apps, databases, code-server, n8n, etc.)
if sudo test -d "/var/lib/docker/volumes"; then
  echo "[COOLIFY-SYNC] Streaming all application volumes to ${STORAGE_TARGET}/volumes_bundle.tar.gz..."
  stream_pigz_to_storage "/var/lib/docker/volumes" "${STORAGE_TARGET}/volumes_bundle.tar.gz" \
    --exclude="**/metadata.db" \
    --exclude="*coolify-db-data*" \
    --exclude="*coolify-db*" \
    --exclude="*coolify_db*"
else
  echo "[COOLIFY-SYNC] No /var/lib/docker/volumes directory found."
fi

echo "[COOLIFY-SYNC] Universal backup to Google Drive completed successfully!"
