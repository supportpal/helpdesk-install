#!/bin/bash

set -eu -o pipefail

LAST_BACKUP_DIR="backup"
LAST_BACKUP_FILE="$(find "${LAST_BACKUP_DIR}" -name '*.tar.gz' -print  | head -n1 | xargs basename)"

if [[ -z "${LAST_BACKUP_FILE}" ]]; then
  echo "No backups found."
  exit 1
fi

TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"

# Determine command path. app:restore moved to app-manager in v4.2.0
GTE_v420="$(docker exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/var/www/supportpal"; else COMMAND_PATH="/var/www/supportpal/app-manager"; fi

echo "Found ${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}..."
echo "Restoring..."

docker exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
docker cp "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}" "supportpal:${TEMP_BACKUP_DIR}/"
TAR_OUTPUT=$(docker exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -xvzf ${LAST_BACKUP_FILE}")
docker exec supportpal bash -c "cd ${COMMAND_PATH} && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force"

# If backup generated via docker, restore volumes.
if echo "${TAR_OUTPUT}" | grep -qs '^volumes-monolithic/$'; then
  echo 'Restoring volume data...'

  docker exec supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/cache/redis-data /"
  docker exec supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy/caddy /"
  rm -rf "backup/${TIMESTAMP}/"
fi
