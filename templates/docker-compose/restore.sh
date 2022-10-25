#!/bin/bash

set -eu -o pipefail

. .env
LAST_BACKUP_DIR="backup/$(ls -1t backup/ | head -n1)"
LAST_BACKUP_FILE=$(ls -1 ${LAST_BACKUP_DIR} | grep 'app-.*gz')


TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
docker exec "${WEB_SERVICE_NAME}" bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
docker cp "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}" "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/"
docker exec "${WEB_SERVICE_NAME}" bash -c "cd /supportpal/app-manager && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force"

docker cp "${LAST_BACKUP_DIR}/cache/data/" "${CACHE_SERVICE_NAME}:/"
docker cp "${LAST_BACKUP_DIR}/mailer/exim4/" "${MAILER_SERVICE_NAME}:/var/spool/"
