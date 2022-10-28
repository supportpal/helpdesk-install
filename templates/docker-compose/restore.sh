#!/bin/bash

set -eu -o pipefail

. .env
LAST_BACKUP_DIR="backup"
LAST_BACKUP_FILE="$(find "${LAST_BACKUP_DIR}" -name '*.tar.gz' -printf "%f\n" | head -n1)"

TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"

# Determine command path. app:restore moved to app-manager in v4.2.0
GTE_v420="$(docker exec supportpal php -r "\$release = require '/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/supportpal"; else COMMAND_PATH="/supportpal/app-manager"; fi

echo "Found ${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}..."
echo "Restoring..."

docker exec "${WEB_SERVICE_NAME}" bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
docker cp "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}" "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/"
TAR_OUTPUT=$(docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${TEMP_BACKUP_DIR} && tar -xvzf ${LAST_BACKUP_FILE}")
docker exec "${WEB_SERVICE_NAME}" bash -c "cd ${COMMAND_PATH} && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force" > /dev/null 2>&1

# If backup generated via docker, restore volumes.
if echo "${TAR_OUTPUT}" | grep -qs '^volumes/$'; then
  echo 'Restoring volume data...'

  mkdir -p "backup/${TIMESTAMP}"
  docker cp "${WEB_SERVICE_NAME}:${TEMP_BACKUP_DIR}/volumes" "backup/${TIMESTAMP}"
  docker cp "backup/${TIMESTAMP}/volumes/cache/data/" "${CACHE_SERVICE_NAME}:/"
  docker cp "backup/${TIMESTAMP}/volumes/mailer/exim4/" "${MAILER_SERVICE_NAME}:/var/spool/"
  rm -rf "backup/${TIMESTAMP}/"
fi
