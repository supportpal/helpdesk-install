#!/bin/bash

set -eu -o pipefail

LAST_BACKUP_DIR="backup"
if [[ ! -d "${LAST_BACKUP_DIR}" ]]; then
  echo "The ${LAST_BACKUP_DIR}/ directory does not exist. Create the directory, add your backup file to it and try again."; exit 1
fi

echo "Searching ${LAST_BACKUP_DIR}/ directory for backups..."

# shellcheck disable=SC2012
LAST_BACKUP_FILE_PATH="$(ls -1t ${LAST_BACKUP_DIR}/app-*.tar.gz | head -n1)"
if [[ ! -f "${LAST_BACKUP_FILE_PATH}" ]]; then
  echo "No backup files found. Add your backup to the ${LAST_BACKUP_DIR}/ directory and try again."; exit 1
fi

LAST_BACKUP_FILE="$(echo "${LAST_BACKUP_FILE_PATH}" | xargs basename)"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"

GTE_v420="$(docker exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "${GTE_v420}" = "1" ]]; then
  echo "Command is only supported after version 4.2.0."
  exit 1
fi

BACKUP_AND_RESTORE_MODE="$(docker exec supportpal bash -c "cat /etc/container_environment/BACKUP_AND_RESTORE_MODE")"
if [[ "${BACKUP_AND_RESTORE_MODE}" = "0" ]]; then
  echo "Backup and restore mode must be enabled.."
  exit 1
fi

echo "Found ${LAST_BACKUP_FILE}..."
echo "Restoring..."

docker exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
docker cp "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}" "supportpal:${TEMP_BACKUP_DIR}/"
TAR_OUTPUT=$(docker exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -xvzf ${LAST_BACKUP_FILE}")
docker exec supportpal bash -c "cd ${COMMAND_PATH} && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force" > /dev/null

# If backup generated via docker, restore volumes.
if echo "${TAR_OUTPUT}" | grep -qs '^volumes-monolithic/$'; then
  echo 'Restoring volume data...'

  docker exec supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/cache/redis-data /"
  docker exec supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy/caddy /"
  rm -rf "backup/${TIMESTAMP}/"
fi
