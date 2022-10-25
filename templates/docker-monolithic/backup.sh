#!/bin/bash

set -eu -o pipefail

. .env
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
FILESYSTEM_BACKUP_NAME="filesystem-${TIMESTAMP}.tar.gz"
APP_BACKUP_NAME="app-${TIMESTAMP}.tar.gz"

echo 'Backing up filesystem...'
docker exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config/production" # create the farthest directory
docker exec supportpal bash -c "cp -r /var/www/supportpal/config/production ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}/config"
docker exec supportpal bash -c "cp -r /var/www/supportpal/storage ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec supportpal bash -c "cp -r /var/www/supportpal/addons ${TEMP_BACKUP_DIR}/filesystem-${TIMESTAMP}"
docker exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${FILESYSTEM_BACKUP_NAME} filesystem-${TIMESTAMP}"

echo 'Backing up Database...'
DB_BACKUP_PATH=$(docker exec -u www-data supportpal bash -c "cd /var/www/supportpal/ && php artisan db:backup | grep -oE '/var/www/supportpal/.*/database-.*'")
DB_FILE_NAME=$(echo "${DB_BACKUP_PATH}" | grep -oE "database-.*")
docker exec supportpal bash -c "mv ${DB_BACKUP_PATH} ${TEMP_BACKUP_DIR}/"

echo 'Combining backups...'
docker exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -czf ${APP_BACKUP_NAME} ${FILESYSTEM_BACKUP_NAME} ${DB_FILE_NAME}"

echo 'Copying backup to host...'
mkdir -p "backup/${TIMESTAMP}/" && docker cp "supportpal:${TEMP_BACKUP_DIR}/${APP_BACKUP_NAME}" "backup/${TIMESTAMP}/"
docker exec supportpal bash -c "rm -rf ${TEMP_BACKUP_DIR}/"

echo 'Backing up caddy and cache...'
mkdir -p "backup/${TIMESTAMP}/cache/" && docker cp "supportpal:/redis-data" "backup/${TIMESTAMP}/cache/"
mkdir -p "backup/${TIMESTAMP}/caddy/" && docker cp "supportpal:/caddy" "backup/${TIMESTAMP}/caddy/"

echo "Backup created successfully at ${PWD}/backup/${TIMESTAMP}"
