#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.

    --online                   Do not restart the services.
"

# Options
online=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  --online) online=true ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
  # shellcheck disable=SC2317
  shift
done

BACKUP_DIR="backup"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
FILESYSTEM_BACKUP_NAME="filesystem-${TIMESTAMP}.tar.gz"
APP_BACKUP_NAME="app-${TIMESTAMP}.tar.gz"

# Determine command path. Some commands moved to app-manager in v4.2.0
GTE_v420="$(docker exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/var/www/supportpal"; else COMMAND_PATH="/var/www/supportpal/app-manager"; fi

if ! $online; then
  echo "Stopping services..."
  docker exec supportpal bash -c "sudo find -L /etc/service -maxdepth 1 -mindepth 1 -type d ! -name 'redis' ! -name '00redis' ! -name 'mysql' ! -name '00mysql' -printf '%f\n' -exec sv stop {} \;"
fi

echo 'Backing up filesystem...'
docker exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config/production" # create the farthest directory
docker exec supportpal bash -c "cp -r /var/www/supportpal/config/production ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config"
docker exec supportpal bash -c "cp -r /var/www/supportpal/storage ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec supportpal bash -c "cp -r /var/www/supportpal/addons ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${FILESYSTEM_BACKUP_NAME} filesystem-${TIMESTAMP}"

echo 'Backing up database...'
DB_BACKUP_PATH=$(docker exec supportpal bash -c "cd ${COMMAND_PATH} && php artisan db:backup --store-local | grep -oE '/var/www/supportpal/.*/database-.*'")
DB_FILE_NAME=$(echo "${DB_BACKUP_PATH}" | xargs basename)
docker exec supportpal bash -c "mv ${DB_BACKUP_PATH} ${TEMP_BACKUP_DIR}/"

echo 'Backing up volume data...'
docker exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/cache && cp -r /redis-data/ ${TEMP_BACKUP_DIR}/volumes-monolithic/cache"
docker exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy && cp -r /caddy/ ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy"
if docker exec -u root supportpal bash -c "test -d /meilisearch"; then
  docker exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/meilisearch && cp -r /meilisearch/ ${TEMP_BACKUP_DIR}/volumes-monolithic/meilisearch"
fi
if docker exec -u root supportpal bash -c "test -d /qdrant"; then
    docker exec -u root supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/volumes-monolithic/qdrant && cp -r /qdrant/ ${TEMP_BACKUP_DIR}/volumes-monolithic/qdrant"
fi

echo 'Combining backups...'
docker exec -u root supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${APP_BACKUP_NAME} ${FILESYSTEM_BACKUP_NAME} ${DB_FILE_NAME} volumes-monolithic/"

echo 'Copying backup to host...'
mkdir -p "${BACKUP_DIR}/"
docker cp "supportpal:${TEMP_BACKUP_DIR}/${APP_BACKUP_NAME}" "${BACKUP_DIR}/"
docker exec -u root supportpal bash -c "rm -rf ${TEMP_BACKUP_DIR}/"

if ! $online; then
  echo "Restarting services..."
  docker restart supportpal
fi

echo "Backup created successfully at ${PWD}/${BACKUP_DIR}/${APP_BACKUP_NAME}"
