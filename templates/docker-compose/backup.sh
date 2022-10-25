#!/bin/bash

set -eu -o pipefail

. .env
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
FILESYSTEM_BACKUP_NAME="filesystem-${TIMESTAMP}.tar.gz"
APP_BACKUP_NAME="app-${TIMESTAMP}.tar.gz"

echo 'Backing up filesystem...'
docker exec "${WEB_SERVICE_NAME}" bash -c "mkdir -p ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config/production" # create the farthest directory
docker exec "${WEB_SERVICE_NAME}" bash -c "cp -r /supportpal/config/production ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config"
docker exec "${WEB_SERVICE_NAME}" bash -c "cp -r /supportpal/storage ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec "${WEB_SERVICE_NAME}" bash -c "cp -r /supportpal/addons ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${FILESYSTEM_BACKUP_NAME} filesystem-${TIMESTAMP}"

echo 'Backing up Database...'
DB_BACKUP_PATH=$(docker exec -u www-data "${WEB_SERVICE_NAME}" bash -c "cd /supportpal/ && php artisan db:backup | grep -oE '/supportpal.*/database-.*'")
DB_FILE_NAME=$(echo "${DB_BACKUP_PATH}" | grep -oE "database-.*")
docker exec "${WEB_SERVICE_NAME}" bash -c "mv ${DB_BACKUP_PATH} ${TEMP_BACKUP_DIR}/"

echo 'Combining backups...'
docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${APP_BACKUP_NAME} ${FILESYSTEM_BACKUP_NAME} ${DB_FILE_NAME}"

echo 'Copying backup to host...'
mkdir -p "backup/${TIMESTAMP}/" && docker cp "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/${APP_BACKUP_NAME}" "backup/${TIMESTAMP}/"
docker exec "${WEB_SERVICE_NAME}" bash -c "rm -rf ${TEMP_BACKUP_DIR}/"

echo 'Backing up cache and mailer temp files...'
mkdir -p "backup/${TIMESTAMP}/cache/" && docker cp "${CACHE_SERVICE_NAME}:/data" "backup/${TIMESTAMP}/cache/"
mkdir -p "backup/${TIMESTAMP}/mailer/" && docker cp "${MAILER_SERVICE_NAME}:/var/spool/exim4" "backup/${TIMESTAMP}/mailer/"

echo "Backup created successfully at ${PWD}/backup/${TIMESTAMP}"
