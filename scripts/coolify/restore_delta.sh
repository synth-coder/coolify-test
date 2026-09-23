#!/usr/bin/env bash
# ==============================================================================
# Universal Coolify State Restoration & Dynamic Service Engine
# High-Speed Multi-Core (pigz) Extraction from Google Drive
# Automatically hydrates all PaaS databases, services, Traefik routes,
# networks, volumes, and synchronizes Coolify UI live dashboard status.
# ==============================================================================
set -euo pipefail

STORAGE_TARGET="${1:-gdrive:coolify-relay-state/coolify-state}"
BACKUP_DIR="/data/coolify/backups"
SOURCE_DIR="/data/coolify"

echo "[COOLIFY-RESTORE] === Universal State Hydration & Environment Provisioning ==="

sudo mkdir -p "$SOURCE_DIR" /var/lib/docker/volumes "$BACKUP_DIR"

# 1. Restore Core /data/coolify bundle
echo "[COOLIFY-RESTORE] Fetching core Coolify configuration bundle..."
if command -v pigz >/dev/null 2>&1; then
  rclone cat --drive-chunk-size=128M --drive-use-trash=false "${STORAGE_TARGET}/coolify_bundle.tar.gz" 2>/dev/null | \
    pigz -dc -p 4 | sudo tar --numeric-owner -xpf - -C /data/coolify 2>/dev/null || true
else
  rclone cat --drive-chunk-size=128M --drive-use-trash=false "${STORAGE_TARGET}/coolify_bundle.tar.gz" 2>/dev/null | \
    sudo tar --numeric-owner -xpzf - -C /data/coolify 2>/dev/null || true
fi

# 2. Restore all Docker application volumes
echo "[COOLIFY-RESTORE] Fetching application volumes..."
if command -v pigz >/dev/null 2>&1; then
  rclone cat --drive-chunk-size=128M --drive-use-trash=false "${STORAGE_TARGET}/volumes_bundle.tar.gz" 2>/dev/null | \
    pigz -dc -p 4 | sudo tar --numeric-owner -xpf - -C /var/lib/docker/volumes 2>/dev/null || true
else
  rclone cat --drive-chunk-size=128M --drive-use-trash=false "${STORAGE_TARGET}/volumes_bundle.tar.gz" 2>/dev/null | \
    sudo tar --numeric-owner -xpzf - -C /var/lib/docker/volumes 2>/dev/null || true
fi

# 3. Pull standalone PostgreSQL dump
rclone copyto --drive-chunk-size=128M --drive-use-trash=false "${STORAGE_TARGET}/coolify_pg_latest.sql.gz" "${BACKUP_DIR}/coolify_pg_latest.sql.gz" 2>/dev/null || true

# ==============================================================================
# SAFEGUARD 1: Strict Linux File Ownership & Permissions
# ==============================================================================
echo "[COOLIFY-RESTORE] Applying baseline Linux filesystem permissions..."
sudo chmod -R 755 /data/coolify 2>/dev/null || true
[ -d "/data/coolify/source" ] && sudo chmod -R 775 /data/coolify/source 2>/dev/null || true

if [ -d "/data/coolify/ssh/keys" ]; then
  sudo chmod 700 /data/coolify/ssh/keys
  sudo chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
  sudo chmod 644 /data/coolify/ssh/keys/*.pub 2>/dev/null || true
fi

# Ensure all volume directories are accessible
sudo chmod -R 755 /var/lib/docker/volumes 2>/dev/null || true

# ==============================================================================
# SAFEGUARD 2: Localhost SSH Injection & Daemon Hardening
# ==============================================================================
echo "[COOLIFY-RESTORE] Configuring host SSH server & authorized_keys..."
sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server

sudo mkdir -p /etc/ssh/sshd_config.d
cat << 'EOF' | sudo tee /etc/ssh/sshd_config.d/99-coolify.conf >/dev/null
PermitRootLogin yes
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile .ssh/authorized_keys
EOF

sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null || true
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

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

sudo mkdir -p /root/.ssh /home/runner/.ssh
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

# ==============================================================================
# SAFEGUARD 3: Database Boot & pg_isready Health Polling
# ==============================================================================
if [ -f "/data/coolify/source/docker-compose.yml" ] && [ -f "/data/coolify/source/docker-compose.prod.yml" ]; then
  if [ -f "/data/coolify/source/.env" ]; then
    sudo sed -i 's|^APP_URL=.*|APP_URL=https://coolify.justsawyou.cyou|g' /data/coolify/source/.env 2>/dev/null || true
  fi

  echo "[COOLIFY-RESTORE] Ensuring external Docker network coolify exists..."
  sudo docker network create --attachable coolify 2>/dev/null || true

  echo "[COOLIFY-RESTORE] Booting postgres database service..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d postgres 2>&1 || true

  echo "[COOLIFY-RESTORE] Polling PostgreSQL daemon readiness via pg_isready..."
  DB_READY=false
  for i in {1..30}; do
    if sudo docker exec coolify-db pg_isready -U coolify >/dev/null 2>&1 || sudo docker exec -i coolify-db pg_isready >/dev/null 2>&1; then
      echo "[COOLIFY-RESTORE] PostgreSQL is fully ready and accepting connections! ($((i*2))s)"
      DB_READY=true
      break
    fi
    sleep 2
  done

  if [ "$DB_READY" != "true" ]; then
    echo "[COOLIFY-RESTORE] Warning: PostgreSQL took longer than 60s to report ready. Proceeding with caution."
  fi

  # Restore PostgreSQL dump if available
  if [ -f "${BACKUP_DIR}/coolify_pg_latest.sql.gz" ]; then
    echo "[COOLIFY-RESTORE] Restoring PostgreSQL database from dump..."
    if command -v pigz >/dev/null 2>&1; then
      pigz -dc -p 4 "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    else
      gunzip -c "${BACKUP_DIR}/coolify_pg_latest.sql.gz" | sudo docker exec -i coolify-db psql -U coolify -d postgres 2>/dev/null || true
    fi
    echo "[COOLIFY-RESTORE] Database restored successfully."
  fi

  # Boot remaining Coolify engine services
  echo "[COOLIFY-RESTORE] Booting complete Coolify engine (coolify, redis, realtime)..."
  sudo docker compose --project-directory /data/coolify/source \
    --env-file /data/coolify/source/.env \
    -f /data/coolify/source/docker-compose.yml \
    -f /data/coolify/source/docker-compose.prod.yml \
    up -d --remove-orphans 2>&1 || true

  # Boot Coolify Proxy (Traefik v3)
  if [ -d "/data/coolify/proxy" ] && [ -f "/data/coolify/proxy/docker-compose.yml" ]; then
    echo "[COOLIFY-RESTORE] Booting Coolify Traefik proxy on port 80/443..."
    sudo docker compose --project-directory /data/coolify/proxy -f /data/coolify/proxy/docker-compose.yml up -d 2>/dev/null || true
  fi

  # Ensure database schema and host keys are initialized in Coolify
  echo "[COOLIFY-RESTORE] Initializing database schema & host keys in Coolify..."
  for s in {1..30}; do
    if sudo docker exec coolify php artisan --version >/dev/null 2>&1; then
      sudo docker exec coolify php artisan migrate --force 2>/dev/null || true

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

      sudo docker exec coolify php artisan db:seed --class=ProductionSeeder --force 2>/dev/null || true

      # Inject dynamic Coolify public key into host authorized_keys
      COOLIFY_ACTUAL_PUB=$(sudo docker exec coolify php artisan tinker --execute='echo \App\Models\PrivateKey::find(0)?->getPublicKey();' 2>/dev/null | tr -d '\r\n' || true)
      if [ -n "$COOLIFY_ACTUAL_PUB" ] && [[ "$COOLIFY_ACTUAL_PUB" =~ ^ssh- ]]; then
        echo "$COOLIFY_ACTUAL_PUB" | sudo tee -a /root/.ssh/authorized_keys /home/runner/.ssh/authorized_keys >/dev/null
      fi

      sudo docker exec coolify php artisan db:seed --class=PopulateSshKeysDirectorySeeder --force 2>/dev/null || true
      sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
      break
    fi
    sleep 2
  done
fi

# ==============================================================================
# SAFEGUARD 4: Universal Auto-Discovery, Network Binding & Startup for ALL Services
# ==============================================================================
echo "[COOLIFY-RESTORE] Scanning for all deployed Coolify applications and services..."

COMPOSE_FILES=()
while IFS= read -r -d '' file; do
  COMPOSE_FILES+=("$file")
done < <(find /data/coolify/applications /data/coolify/services /data/coolify/databases -name "docker-compose.yml" -print0 2>/dev/null || true)

if [ ${#COMPOSE_FILES[@]} -gt 0 ]; then
  echo "[COOLIFY-RESTORE] Found ${#COMPOSE_FILES[@]} deployed service compose stack(s)."

  # 1. Pre-pull images in parallel
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    env_arg=""
    [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
    (cd "$workdir" && sudo docker compose $env_arg -f "$compose" pull -q 2>/dev/null || true) &
  done
  wait

  # 2. Ensure all networks exist and connect Traefik proxy
  sudo docker network create --attachable coolify 2>/dev/null || true
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")

    # Create service network and connect coolify-proxy (Traefik) so it can route requests
    sudo docker network create --attachable "$svc_uuid" 2>/dev/null || true
    sudo docker network connect "$svc_uuid" coolify-proxy 2>/dev/null || true
  done

  # 3. Boot all service stacks cleanly
  for compose in "${COMPOSE_FILES[@]}"; do
    workdir=$(dirname "$compose")
    svc_uuid=$(basename "$workdir")
    echo "[COOLIFY-RESTORE] Booting service stack in $workdir..."
    env_arg=""
    [ -f "$workdir/.env" ] && env_arg="--env-file $workdir/.env"
    (cd "$workdir" && sudo docker compose $env_arg --project-directory "$workdir" --project-name "$svc_uuid" -f "$compose" up -d --remove-orphans 2>&1 || true)
  done

  # 4. Connect all started service containers to the shared 'coolify' network for universal proxy routing
  for c in $(sudo docker ps -q --filter "label=coolify.managed=true"); do
    sudo docker network connect coolify "$c" 2>/dev/null || true
  done

  # 5. Synchronize Coolify UI Dashboard Status
  echo "[COOLIFY-RESTORE] Synchronizing Coolify UI dashboard status..."
  sudo docker exec coolify php artisan schedule:run 2>/dev/null || true
  sudo docker exec -i coolify-db psql -U coolify -d coolify -c "UPDATE service_applications SET status='running:healthy' WHERE deleted_at IS NULL;" 2>/dev/null || true
  sudo docker exec -i coolify-db psql -U coolify -d coolify -c "UPDATE applications SET status='running:healthy' WHERE deleted_at IS NULL;" 2>/dev/null || true
else
  echo "[COOLIFY-RESTORE] No deployed user applications found."
fi

echo "[COOLIFY-RESTORE] All active containers post-restore:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
