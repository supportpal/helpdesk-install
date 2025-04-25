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
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
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

echo 'Backing up filesystem...'
docker compose exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config/production" # create the farthest directory
docker compose exec supportpal bash -c "cp -r /var/www/supportpal/config/production ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config"
docker compose exec supportpal bash -c "cp -r /var/www/supportpal/storage ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker compose exec supportpal bash -c "cp -r /var/www/supportpal/addons ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker compose exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${FILESYSTEM_BACKUP_NAME} filesystem-${TIMESTAMP}"

echo 'Backing up database...'
DB_BACKUP_PATH=$(docker compose exec supportpal bash -c "cd ${COMMAND_PATH} && php artisan db:backup --store-local | grep -oE '/var/www/supportpal/.*/database-.*'")
DB_FILE_NAME=$(echo "${DB_BACKUP_PATH}" | xargs basename)
docker compose exec supportpal bash -c "mv ${DB_BACKUP_PATH} ${TEMP_BACKUP_DIR}/"

echo 'Backing up volume data...'
docker compose exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/cache && cp -r /redis-data/ ${TEMP_BACKUP_DIR}/volumes-monolithic/cache"
docker compose exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy && cp -r /caddy/ ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy"
if docker compose exec -u root supportpal bash -c "test -d /meilisearch"; then
  docker compose exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/meilisearch && cp -r /meilisearch/ ${TEMP_BACKUP_DIR}/volumes-monolithic/meilisearch"
fi
if docker compose exec -u root supportpal bash -c "test -d /qdrant"; then
    docker compose exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/qdrant && cp -r /qdrant/ ${TEMP_BACKUP_DIR}/volumes-monolithic/qdrant"
fi

TMP_DIR="/tmp/backup_$(date +%s)_$RANDOM"
mkdir -p "$TMP_DIR"

echo "Backing up current working directory: $(pwd)..."
tar -czf "$TMP_DIR/docker-files.tar.gz" --exclude="./${BACKUP_DIR}" .

# Copy files to host.
execute_command "docker cp ""supportpal:${TEMP_BACKUP_DIR}/${FILESYSTEM_BACKUP_NAME}"" ""${TMP_DIR}"""
execute_command "docker cp ""supportpal:${TEMP_BACKUP_DIR}/${DB_FILE_NAME}"" ""${TMP_DIR}"""
execute_command "docker cp ""supportpal:${TEMP_BACKUP_DIR}/volumes-monolithic"" ""${TMP_DIR}"""

# Combine backup files.
mkdir -p "${ABS_BACKUP_PATH}/"
(cd "$TMP_DIR" && tar -czf "${ABS_BACKUP_PATH}/${APP_BACKUP_NAME}" "${FILESYSTEM_BACKUP_NAME}" "${DB_FILE_NAME}" volumes-monolithic/ docker-files.tar.gz)

# Cleanup.
docker compose exec -u root supportpal bash -c "rm -rf ${TEMP_BACKUP_DIR}/"
rm -rf "$TMP_DIR"

echo "Backup created successfully at ${ABS_BACKUP_PATH}/${APP_BACKUP_NAME}"
echo

if ! $online; then
  echo "Restarting services..."
  execute_command "docker restart supportpal"
fi
