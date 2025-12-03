#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.
    --online                   Do not restart the services.
    --debug                    Enable verbose output.
"

# Options
online=false
debug=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  --online) online=true ;;
  --debug) debug=true ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
  # shellcheck disable=SC2317
  shift
done

if $debug; then
  set -x
fi

execute_command() {
    local cmd="$1"

    if [ "$debug" = false ]; then
        eval "$cmd > /dev/null 2>&1"
    else
        eval "$cmd"
    fi
}

BACKUP_DIR="backup"
ABS_BACKUP_PATH="$(pwd)/${BACKUP_DIR}"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
TMP_DIR="${ABS_BACKUP_PATH}/tmp-${TIMESTAMP}"
FILESYSTEM_BACKUP_NAME="filesystem-${TIMESTAMP}.tar.gz"
APP_BACKUP_NAME="app-${TIMESTAMP}.tar.gz"

# Make sure that the script is executed in the directory where docker-compose.yml is.
if ! docker compose config 2>/dev/null | grep -q "container_name: supportpal"; then
    echo "error: the script must be executed in your SupportPal installation directory (where your docker-compose.yml file is)."
    exit 1
fi

echo "[NOTICE]"
echo "The backup includes all files in the current working directory ($(pwd))."
echo
echo "It is recommended to move your installation files (docker-compose.yml, docker-compose.override.yml, .env, etc) to"
echo "a separate directory, to avoid including unnecessary files in the backup."
echo

# Determine command path. Some commands moved to app-manager in v4.2.0
GTE_v420="$(docker compose exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/var/www/supportpal"; else COMMAND_PATH="/var/www/supportpal/app-manager"; fi

if ! $online; then
  echo "Stopping services..."
  docker compose exec supportpal bash -c "
    sudo find -L /etc/service -maxdepth 1 -mindepth 1 -type d \
    ! -name 'redis' ! -name '00redis' ! -name 'mysql' ! -name '00mysql' \
    -printf '%f\n' -exec sv stop {} \; $(if [ "$debug" = false ]; then echo '> /dev/null 2>&1'; fi)
  "
fi

# Ensure backup directory exists before using TMP_DIR
mkdir -p "${ABS_BACKUP_PATH}/"

echo 'Backing up filesystem...'
mkdir -p "${TMP_DIR}/filesystem-${TIMESTAMP}/config"
docker cp supportpal:/var/www/supportpal/config/production "${TMP_DIR}/filesystem-${TIMESTAMP}/config/" || { echo "error: failed to copy config/production from container"; exit 1; }
docker cp supportpal:/var/www/supportpal/storage "${TMP_DIR}/filesystem-${TIMESTAMP}/" || { echo "error: failed to copy storage from container"; exit 1; }
docker cp supportpal:/var/www/supportpal/addons "${TMP_DIR}/filesystem-${TIMESTAMP}/" || { echo "error: failed to copy addons from container"; exit 1; }
(cd "${TMP_DIR}" && tar -czf "${FILESYSTEM_BACKUP_NAME}" "filesystem-${TIMESTAMP}" && rm -rf "filesystem-${TIMESTAMP}")

echo 'Backing up database...'
DB_BACKUP_PATH=$(docker compose exec supportpal bash -c "cd ${COMMAND_PATH} && php artisan db:backup --store-local | grep -oE '/var/www/supportpal/.*/database-.*'")
DB_FILE_NAME=$(echo "${DB_BACKUP_PATH}" | xargs basename)
docker cp "supportpal:${DB_BACKUP_PATH}" "${TMP_DIR}/" || { echo "error: failed to copy database backup from container"; exit 1; }
docker compose exec supportpal bash -c "rm ${DB_BACKUP_PATH}"

echo 'Backing up volume data...'
mkdir -p "${TMP_DIR}/volumes-monolithic/cache"
mkdir -p "${TMP_DIR}/volumes-monolithic/caddy"
docker cp supportpal:/redis-data "${TMP_DIR}/volumes-monolithic/cache/" || { echo "error: failed to copy redis-data from container"; exit 1; }
docker cp supportpal:/caddy "${TMP_DIR}/volumes-monolithic/caddy/" || { echo "error: failed to copy caddy from container"; exit 1; }
if docker compose exec -u root supportpal bash -c "test -d /meilisearch"; then
  mkdir -p "${TMP_DIR}/volumes-monolithic/meilisearch"
  docker cp supportpal:/meilisearch "${TMP_DIR}/volumes-monolithic/meilisearch/" || { echo "error: failed to copy meilisearch from container"; exit 1; }
fi
if docker compose exec -u root supportpal bash -c "test -d /qdrant"; then
  mkdir -p "${TMP_DIR}/volumes-monolithic/qdrant"
  docker cp supportpal:/qdrant "${TMP_DIR}/volumes-monolithic/qdrant/" || { echo "error: failed to copy qdrant from container"; exit 1; }
fi

echo "Backing up current working directory: $(pwd)..."
tar -czf "$TMP_DIR/docker-files.tar.gz" --exclude="./${BACKUP_DIR}" .

# Combine backup files.
(cd "$TMP_DIR" && tar -czf "${ABS_BACKUP_PATH}/${APP_BACKUP_NAME}" "${FILESYSTEM_BACKUP_NAME}" "${DB_FILE_NAME}" volumes-monolithic/ docker-files.tar.gz)

# Cleanup (now only needs to clean the host TMP_DIR, container cleanup is minimal)
rm -rf "$TMP_DIR"

echo "Backup created successfully at ${ABS_BACKUP_PATH}/${APP_BACKUP_NAME}"
echo

if ! $online; then
  echo "Restarting services..."
  execute_command "docker restart supportpal"
fi
