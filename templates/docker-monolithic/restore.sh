#!/bin/bash

set -eu -o pipefail

LAST_BACKUP_DIR="backup/$(ls -1t backup/ | head -n1)"
LAST_BACKUP_FILE=$(ls -1 ${LAST_BACKUP_DIR} | grep 'app-.*gz')


TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"
docker exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
docker cp "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}" "supportpal:${TEMP_BACKUP_DIR}/"
docker exec supportpal bash -c "cd /var/www/supportpal && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force"

docker cp "${LAST_BACKUP_DIR}/cache/redis-data" "supportpal:/"
docker cp "${LAST_BACKUP_DIR}/caddy/caddy/" "supportpal:/"
