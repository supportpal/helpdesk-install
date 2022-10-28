#!/bin/bash

set -eu -o pipefail

. .env
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
FILESYSTEM_BACKUP_NAME="filesystem-${TIMESTAMP}.tar.gz"
APP_BACKUP_NAME="app-${TIMESTAMP}.tar.gz"

# Determine command path. Some commands moved to app-manager in v4.2.0
GTE_v420="$(docker exec supportpal php -r "\$release = require '/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/supportpal"; else COMMAND_PATH="/supportpal/app-manager"; fi

echo 'Backing up filesystem...'
docker exec "${WEB_SERVICE_NAME}" bash -c "mkdir -p ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config/production" # create the farthest directory
docker exec "${WEB_SERVICE_NAME}" bash -c "cp -r /supportpal/config/production ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config"
docker exec "${WEB_SERVICE_NAME}" bash -c "cp -r /supportpal/storage ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec "${WEB_SERVICE_NAME}" bash -c "cp -r /supportpal/addons ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${FILESYSTEM_BACKUP_NAME} filesystem-${TIMESTAMP}"

echo 'Backing up database...'
DB_BACKUP_PATH=$(docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${COMMAND_PATH} && php artisan db:backup | grep -oE '/supportpal.*/database-.*'")
DB_FILE_NAME=$(echo "${DB_BACKUP_PATH}" | xargs basename)
docker exec "${WEB_SERVICE_NAME}" bash -c "mv ${DB_BACKUP_PATH} ${TEMP_BACKUP_DIR}/"

echo 'Backing up volume data...'
mkdir -p "backup/${TIMESTAMP}/volumes/cache/" && docker cp "${CACHE_SERVICE_NAME}:/data" "backup/${TIMESTAMP}/volumes/cache"
mkdir -p "backup/${TIMESTAMP}/volumes/mailer/" && docker cp "${MAILER_SERVICE_NAME}:/var/spool/exim4" "backup/${TIMESTAMP}/volumes/mailer"
docker cp "backup/${TIMESTAMP}/volumes/" "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/"
rm -rf "backup/${TIMESTAMP}/"

echo 'Combining backups...'
docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${APP_BACKUP_NAME} ${FILESYSTEM_BACKUP_NAME} ${DB_FILE_NAME} volumes/"

echo 'Copying backup to host...'
docker cp "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/${APP_BACKUP_NAME}" "backup/"
docker exec "${WEB_SERVICE_NAME}" bash -c "rm -rf ${TEMP_BACKUP_DIR}/"
echo "Backup created successfully at ${PWD}/backup/${APP_BACKUP_NAME}"
