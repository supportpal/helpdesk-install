#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.
    --debug                    Enable verbose output.
"

# Options
debug=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  --debug) debug=true ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
  # shellcheck disable=SC2317
  shift
done

if $debug; then
  set -x
fi

execute_command() {
    local cmd="$1"

    if [ "$debug" = false ]; then
        eval "$cmd > /dev/null 2>&1"
    else
        eval "$cmd"
    fi
}

# Function to detect compression and return appropriate tar flags
get_tar_flags() {
    local file="$1"
    local operation="$2"  # 't' for list, 'x' for extract

    if [[ "$file" == *.tar.gz ]]; then
        echo "${operation}zf"
    else
        echo "${operation}f"
    fi
}

LAST_BACKUP_DIR="$(pwd)/backup"
if [[ ! -d "${LAST_BACKUP_DIR}" ]]; then
  echo "The ${LAST_BACKUP_DIR}/ directory does not exist. Create the directory, add your backup file to it and try again."; exit 1
fi

echo "Searching ${LAST_BACKUP_DIR}/ directory for backups..."

# Search for the most recent .tar.gz or .tar file
LAST_BACKUP_FILE_PATH=""
for pattern in "app-*.tar.gz" "app-*.tar"; do
    files=$(find "${LAST_BACKUP_DIR}/" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')
    if [[ -n "$files" ]]; then
        LAST_BACKUP_FILE_PATH=$(printf '%s\n%s' "$LAST_BACKUP_FILE_PATH" "$files" | sort -r | head -n1)
    fi
done

if [[ ! -f "${LAST_BACKUP_FILE_PATH}" ]]; then
  echo "No backup files found. Add your backup to the ${LAST_BACKUP_DIR}/ directory and try again."; exit 1
fi

LAST_BACKUP_FILE="$(echo "${LAST_BACKUP_FILE_PATH}" | xargs basename)"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"

echo "Found ${LAST_BACKUP_FILE}..."

# List the contents of the archive, and if it contains "docker-files" then restore those files.
TAR_LIST_FLAGS=$(get_tar_flags "$LAST_BACKUP_FILE" "t")
if tar -$TAR_LIST_FLAGS "${LAST_BACKUP_DIR}/$LAST_BACKUP_FILE" 2>/dev/null | grep -qs "^docker-files.tar.gz"; then
  PARENT_DIR="$(realpath "$(pwd)/../")"
  RESTORE_PATH="${PARENT_DIR}/supportpal_$(date +%s)_$RANDOM"

  echo "The backup will be restored to $RESTORE_PATH. Do you want to proceed? [Y/n]"
  read -r PROCEED
  if [ "${PROCEED}" != "Y" ] ; then
    exit 0
  fi

  # Check if container already exists.
  if [[ -n "$(docker ps -a -q -f name=^supportpal$)" ]]; then
      echo "Container with name 'supportpal' already exists. Do you want to remove that container? [Y/n]"
      read -r PROCEED
      if [ "${PROCEED}" != "Y" ] ; then
        exit 0
      fi

      echo "Deleting existing 'supportpal' container and associated volumes..."

      execute_command "docker stop supportpal"
      execute_command "docker rm supportpal"
      execute_command "docker volume rm supportpal_db"
      execute_command "docker volume rm supportpal_config"
      execute_command "docker volume rm supportpal_redis"
      execute_command "docker volume rm supportpal_storage"
      execute_command "docker volume rm supportpal_logs"
      execute_command "docker volume rm supportpal_addons"
      execute_command "docker volume rm supportpal_caddy"
      execute_command "docker volume rm supportpal_meilisearch"
      execute_command "docker volume rm supportpal_qdrant"
  fi

  echo "Restoring docker files to $RESTORE_PATH..."

  # Extract docker-files.tar.gz from the backup file to the restore path.
  TAR_EXTRACT_FLAGS=$(get_tar_flags "$LAST_BACKUP_FILE" "x")
  mkdir -p "$RESTORE_PATH"
  cp "${LAST_BACKUP_DIR}/$LAST_BACKUP_FILE" "$RESTORE_PATH"
  (cd "$RESTORE_PATH" && tar -$TAR_EXTRACT_FLAGS "$LAST_BACKUP_FILE" docker-files.tar.gz)
  (cd "$RESTORE_PATH" && tar -xzf docker-files.tar.gz && rm -f docker-files.tar.gz)

  cd "$RESTORE_PATH"

  # Create volumes.
  execute_command "docker compose config --volumes | xargs -I {} docker volume create {}"

  # Start the container.
  echo "Starting container..."
  execute_command "docker compose up -d"

  # Wait for container to initialise.
  CONTAINER_ENV_PATH="/etc/container_environment.sh"
  docker compose exec -e CONTAINER_ENV_PATH="$CONTAINER_ENV_PATH" supportpal bash -c '
  echo -n "Waiting for container setup to complete."

  FILE="/etc/container_environment.sh"
  while [ -z "${MYSQL_PASSWORD+x}" ] || [ -z "${INITIALIZED+x}" ]; do
    if [ -f "$FILE" ]; then
      source <(sudo cat "$FILE")
    fi

    echo -n "."
    sleep 1
  done

  echo
  echo "The restore will ask you to provide database connection details. Use the details below:"
  echo
  echo "Host: 127.0.0.1"
  echo "Port: 3306"
  echo "Database: $MYSQL_DATABASE"
  echo "Username: $MYSQL_USER"
  echo "Password: $MYSQL_PASSWORD"
  echo "Root password: $MYSQL_ROOT_PASSWORD"
  echo
  '
fi

# Determine command path. app:restore moved to app-manager in v4.2.0
GTE_v420="$(docker compose exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
if [[ "$GTE_v420" = "0" ]]; then COMMAND_PATH="/var/www/supportpal"; else COMMAND_PATH="/var/www/supportpal/app-manager"; fi

echo "Stopping services..."
docker compose exec supportpal bash -c "
    sudo find -L /etc/service -maxdepth 1 -mindepth 1 -type d \
    ! -name 'redis' ! -name '00redis' ! -name 'mysql' ! -name '00mysql' \
    -printf '%f\n' -exec sv stop {} \; $(if [ "$debug" = false ]; then echo '> /dev/null 2>&1'; fi)
  "

echo "Restoring..."

docker compose exec supportpal bash -c "mkdir -p ${TEMP_BACKUP_DIR}"
execute_command "docker cp ""${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}"" ""supportpal:${TEMP_BACKUP_DIR}/"""
TAR_EXTRACT_FLAGS=$(get_tar_flags "$LAST_BACKUP_FILE" "xv")
TAR_OUTPUT=$(docker compose exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -${TAR_EXTRACT_FLAGS} ${LAST_BACKUP_FILE}")
docker compose exec supportpal bash -c "cd ${COMMAND_PATH} && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force"

# If backup generated via docker, restore volumes.
if echo "${TAR_OUTPUT}" | grep -qs '^volumes-monolithic/$'; then
  echo 'Restoring volume data...'

  docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/cache/redis-data /"
  docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy/caddy /"
  if echo "${TAR_OUTPUT}" | grep -qs '^volumes-monolithic/meilisearch'; then
    docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/meilisearch/meilisearch /"
  fi
  if echo "${TAR_OUTPUT}" | grep -qs '^volumes-monolithic/qdrant'; then
    docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/qdrant/qdrant /"
  fi
  rm -rf "backup/${TIMESTAMP}/"
fi

echo "Restarting services..."
execute_command "docker compose down"
execute_command "docker compose up -d"

if [[ -n "${RESTORE_PATH+x}" ]]; then
  echo
  echo "Successfully restored to $RESTORE_PATH"
fi
