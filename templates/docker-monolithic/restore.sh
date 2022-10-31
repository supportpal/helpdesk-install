#!/bin/bash

set -eu -o pipefail

# usage: version_ge <installed_version> <minimum_version>
version_ge() {
  if ! [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; then
    printf "error: %s is less than minimum required version of %s\n" "$1" "$2"
    exit 1
  fi
}

check_docker_compose() {
  local min="2.2.1" version command_status

  set +e
  version="$(docker compose version --short 2>&1)"
  command_status="$?"
  set -e

  if [ $command_status -ne 0 ]; then
    printf "error: Install docker compose using the official installation instructions: https://docs.docker.com/compose/install/\n"
    exit 1
  fi

  version="${version#v}"
  printf "Checking docker compose version %s >= %s ... " "$version" "$min"
  version_ge "$version" "$min"
  printf "✔\n"
}

check_docker_compose

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

# Determine command path. app:restore moved to app-manager in v4.2.0
GTE_v420="$(docker exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/var/www/supportpal"; else COMMAND_PATH="/var/www/supportpal/app-manager"; fi

echo "Found ${LAST_BACKUP_FILE}..."

echo "Stopping services..."
docker exec supportpal bash -c "find -L /etc/service -maxdepth 1 -mindepth 1 -type d ! -name 'redis' ! -name 'mysql' -printf '%f\n' -exec sv stop {} \;"  > /dev/null

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

echo "Restarting services..."
docker compose restart 2> /dev/null
