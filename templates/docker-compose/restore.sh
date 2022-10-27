#!/bin/bash

set -eu -o pipefail

. .env
LAST_BACKUP_FILE="$(ls -1t backup/ | grep 'tar\.gz' | head -n1)"
LAST_BACKUP_DIR="backup"

TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"

docker exec "${WEB_SERVICE_NAME}" bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
docker cp "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}" "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/"
TAR_OUTPUT=$(docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${TEMP_BACKUP_DIR} && tar -xvzf ${LAST_BACKUP_FILE}")
docker exec -u www-data "${WEB_SERVICE_NAME}" bash -c "cd /supportpal/app-manager && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force"

if  echo "${TAR_OUTPUT}" | grep -qs 'volumes'; then
  # restoring a backup generated via docker.
  mkdir -p "backup/${TIMESTAMP}"
  docker cp "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/volumes" "backup/${TIMESTAMP}"
  docker cp "backup/${TIMESTAMP}/volumes/cache/data/" "${CACHE_SERVICE_NAME}:/"
  docker cp "backup/${TIMESTAMP}/volumes/mailer/exim4/" "${MAILER_SERVICE_NAME}:/var/spool/"
fi

rm -rf "backup/${TIMESTAMP}/"
