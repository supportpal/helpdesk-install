#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.
    --file=<path>              Backup archive to restore. Defaults to the most recent backup/app-* archive.
                               Pass a backup/pre-upgrade-*.tar.gz archive (created by backup.sh --pre-upgrade)
                               to roll back the installation in the current directory to that point.
    --debug                    Enable verbose output.
"

# Options
backup_file=""
debug=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  --file) [[ "$#" -ge 2 ]] || { echo "$usage"; exit 1; }; backup_file="$2"; shift ;;
  --file=*) backup_file="${1#*=}" ;;
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

# Asks the user to confirm the action described by the preceding output. Exits unless the answer is Y.
confirm() {
  echo "Do you want to proceed? [Y/n]"
  read -r PROCEED
  if [ "${PROCEED}" != "Y" ] ; then
    exit 0
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

# Label that backup.sh puts on the volumes it creates, with the backup timestamp as its value.
VOLUME_LABEL="com.supportpal.backup"

# Reads the manifest at the start of an archive created by backup.sh, without decompressing the rest of it.
# Prints nothing for other archive formats.
read_manifest() {
  set +o pipefail
  gzip -dc "$1" 2>/dev/null | head -c 1048576 | tar -xOf - manifest.txt 2>/dev/null
  set -o pipefail
  return 0
}

# Asks where the backup should be restored to and removes the existing installation, if any. Sets RESTORE_PATH.
prepare_fresh_install() {
  RESTORE_PATH="$(realpath "$(pwd)/../")/supportpal_$(date +%s)_$RANDOM"

  echo "The backup will be restored to ${RESTORE_PATH}."
  confirm

  # Check if container already exists.
  if [[ -n "$(docker ps -a -q -f name=^supportpal$)" ]]; then
      echo "A container named 'supportpal' already exists. It will be removed along with its docker volumes."
      confirm

      echo "Removing the existing 'supportpal' container and its docker volumes..."

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
      execute_command "docker volume rm supportpal_qdrant || true"
  fi

  mkdir -p "$RESTORE_PATH"
}

# Restores a backup created by backup.sh: a single archive holding the docker files and the contents of each docker
# volume, extracted in one pass by a helper container with the restore directory and every volume mounted.
volume_restore() {
  local manifest="$1" image volume mounts=() existing=()

  image="$(awk '$1 == "image" {print $2}' <<< "${manifest}")"

  # Volumes may be left over from an installation whose container has already been removed.
  while read -r volume; do
    if docker volume inspect "${volume}" > /dev/null 2>&1; then
      existing+=("${volume}")
    fi
  done < <(awk '$1 == "volume" {print $2}' <<< "${manifest}")
  if [[ ${#existing[@]} -gt 0 ]]; then
    echo "The following docker volumes already exist and will be replaced: ${existing[*]}."
    confirm
    for volume in "${existing[@]}"; do
      execute_command "docker volume rm ${volume}"
    done
  fi

  while read -r volume; do
    execute_command "docker volume create ${volume}"
    mounts+=(-v "${volume}:/volumes/${volume}")
  done < <(awk '$1 == "volume" {print $2}' <<< "${manifest}")

  echo "Restoring to ${RESTORE_PATH}, this may take a while..."
  docker run --rm --init -u root --entrypoint bash \
    -e BACKUP_FILE="${LAST_BACKUP_FILE}" \
    -e OWNER="$(id -u):$(id -g)" \
    -v "${LAST_BACKUP_DIR}:/backup:ro" \
    -v "${RESTORE_PATH}:/docker-files" \
    "${mounts[@]}" \
    "${image}" -c 'tar -C / -I "$(command -v pigz || command -v gzip)" -xf "/backup/${BACKUP_FILE}" docker-files volumes && chown -R "${OWNER}" /docker-files'

  cd "$RESTORE_PATH"

  # Create any volumes declared by the compose file that were not in the backup.
  execute_command "docker compose config --volumes | xargs -I {} docker volume create {}"

  echo "Starting container..."
  execute_command "docker compose up -d"

  echo
  echo "Restored successfully to ${RESTORE_PATH}"
}

# Rolls the installation in the current directory back to a rollback point created by backup.sh --pre-upgrade:
# restores the docker files from the archive and the volumes from their <volume>_pre_upgrade copies.
pre_upgrade_restore() {
  local archive="$1" manifest timestamp copied volume clone image

  # Make sure that the script is executed in the directory where docker-compose.yml is.
  if ! grep -q "container_name: supportpal" < <(docker compose config 2>/dev/null); then
    echo "error: the script must be executed in your SupportPal installation directory (where your docker-compose.yml file is)"
    exit 1
  fi

  # Check that every volume copy still exists and belongs to this archive before changing anything, as the copies
  # are replaced by each backup.sh --pre-upgrade run and removed once an upgrade has been verified.
  manifest="$(tar -xzOf "${archive}" pre-upgrade-manifest.txt 2>/dev/null || true)"
  timestamp="$(awk '$1 == "timestamp" {print $2}' <<< "${manifest}")"
  copied="$(awk '$1 == "volume" {print $2}' <<< "${manifest}")"
  if [[ -z "${timestamp}" || -z "${copied}" ]]; then
    echo "error: $(basename "${archive}") was not created by backup.sh --pre-upgrade"
    exit 1
  fi
  for volume in ${copied}; do
    clone="${volume}_pre_upgrade"
    if ! grep -q "\"${VOLUME_LABEL}\":\"${timestamp}\"" < <(docker volume inspect --format '{{json .Labels}}' "${clone}" 2>/dev/null); then
      echo "error: the ${clone} docker volume is missing or belongs to a different rollback point"
      echo "hint: it is not possible to roll back to $(basename "${archive}"), restore a full backup instead"
      exit 1
    fi
  done

  echo "The installation in $(pwd) will be rolled back to the point captured in $(basename "${archive}"). The docker"
  echo "files in this directory will be replaced with the copies in the archive, and the docker volumes will be"
  echo "replaced with their <volume>_pre_upgrade copies."
  confirm

  echo "Restoring docker files to $(pwd)..."
  tar -xzf "${archive}" --exclude="./backup" --exclude="pre-upgrade-manifest.txt"

  echo "Stopping container..."
  execute_command "docker compose down"

  image="$(docker compose config 2>/dev/null | grep -m1 -E '^[[:space:]]*image:' | awk '{print $2}')"
  for volume in $(docker compose config --volumes); do
    clone="${volume}_pre_upgrade"

    # storage/ and the logs are not copied by backup.sh --pre-upgrade, as an upgrade does not modify them.
    if ! grep -qx "${volume}" <<< "${copied}"; then
      if ! docker volume inspect "${volume}" > /dev/null 2>&1; then
        echo "warning: ${volume} no longer exists, it has been recreated empty and must be restored from a full backup"
        execute_command "docker volume create ${volume}"
      fi
      continue
    fi

    echo "Restoring ${volume} from ${clone}..."
    execute_command "docker volume create ${volume}"
    docker run --rm --init -u root --entrypoint bash \
      -v "${clone}:/from:ro" \
      -v "${volume}:/to" \
      "${image}" -c 'find /to -mindepth 1 -delete && cp -a --reflink=auto /from/. /to/'
  done

  echo "Starting container..."
  execute_command "docker compose up -d"

  echo
  echo "Rolled back successfully to $(basename "${archive}")"
  echo
  echo "The rollback point has been kept. Once it is no longer needed, remove it to free the disk space:"
  echo
  echo "    docker volume rm $(for volume in ${copied}; do printf '%s_pre_upgrade ' "${volume}"; done)"
  echo "    rm ${archive}"
  echo
}

if [[ -n "${backup_file}" ]]; then
  if [[ ! -f "${backup_file}" ]]; then
    echo "error: file not found: ${backup_file}"; exit 1
  fi
  LAST_BACKUP_FILE_PATH="$(realpath "${backup_file}")"
  LAST_BACKUP_DIR="$(dirname "${LAST_BACKUP_FILE_PATH}")"

  if [[ "$(basename "${LAST_BACKUP_FILE_PATH}")" == pre-upgrade-* ]]; then
    pre_upgrade_restore "${LAST_BACKUP_FILE_PATH}"
    exit 0
  fi
else
  LAST_BACKUP_DIR="$(pwd)/backup"
  if [[ ! -d "${LAST_BACKUP_DIR}" ]]; then
    echo "error: the ${LAST_BACKUP_DIR}/ directory does not exist"
    echo "hint: create the directory, add your backup file to it and try again"
    exit 1
  fi

  echo "Searching ${LAST_BACKUP_DIR}/ directory for backups..."

  # Search for the most recent .tar.gz or .tar file
  # Collect all matching backup files into an array
  backup_files=()
  for pattern in "app-*.tar.gz" "app-*.tar"; do
      # shellcheck disable=SC2086
      for file in "${LAST_BACKUP_DIR}/"${pattern}; do
          if [[ -f "$file" ]]; then
              backup_files+=("$file")
          fi
      done
  done

  # Select the most recent backup file
  if [[ ${#backup_files[@]} -gt 0 ]]; then
      LAST_BACKUP_FILE_PATH=$(printf '%s\n' "${backup_files[@]}" | sort -r | head -n1)
  else
      LAST_BACKUP_FILE_PATH=""
  fi
  if [[ ! -f "${LAST_BACKUP_FILE_PATH}" ]]; then
    echo "error: no backup files found in the ${LAST_BACKUP_DIR}/ directory"
    echo "hint: add your backup to the directory and try again"
    exit 1
  fi
fi

LAST_BACKUP_FILE="$(echo "${LAST_BACKUP_FILE_PATH}" | xargs basename)"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S-%s)
TEMP_BACKUP_DIR="/tmp/tmp-backups/${TIMESTAMP}"

echo "Found ${LAST_BACKUP_FILE}..."

MANIFEST="$(read_manifest "${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}")"
if [[ "${MANIFEST}" == format* ]]; then
  prepare_fresh_install
  volume_restore "${MANIFEST}"
  exit 0
fi

# List the contents of the archive, and if it contains "docker-files" then restore those files.
TAR_LIST_FLAGS=$(get_tar_flags "$LAST_BACKUP_FILE" "t")
ARCHIVE_CONTENTS="$(tar "-$TAR_LIST_FLAGS" "${LAST_BACKUP_DIR}/$LAST_BACKUP_FILE" 2>/dev/null || true)"

if grep -qs "^docker-files.tar.gz" <<< "${ARCHIVE_CONTENTS}"; then
  prepare_fresh_install

  echo "Restoring docker files to $RESTORE_PATH..."

  # Extract docker-files.tar.gz from the backup file to the restore path.
  TAR_EXTRACT_FLAGS=$(get_tar_flags "$LAST_BACKUP_FILE" "x")
  cp "${LAST_BACKUP_DIR}/$LAST_BACKUP_FILE" "$RESTORE_PATH"
  (cd "$RESTORE_PATH" && tar "-$TAR_EXTRACT_FLAGS" "$LAST_BACKUP_FILE" docker-files.tar.gz)
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
  while { [ "${MYSQL_ENABLED:-1}" = "1" ] && [ -z "${MYSQL_PASSWORD+x}" ]; } || [ -z "${INITIALIZED+x}" ]; do
    if [ -f "$FILE" ]; then
      source <(sudo cat "$FILE")
    fi

    echo -n "."
    sleep 1
  done

  echo
  if [ "${MYSQL_ENABLED:-1}" != "1" ]; then
    echo "notice: the bundled MySQL server is disabled (MYSQL_ENABLED=0), only the filesystem will be restored"
    echo "hint: restoring your external database server is your responsibility"
    echo "hint: the helpdesk will connect to the external database configured in the backup (config/production/database.php)"
    echo
  else
    echo "The restore will ask you to provide database connection details. Use the details below:"
    echo
    echo "Host: 127.0.0.1"
    echo "Port: 3306"
    echo "Database: $MYSQL_DATABASE"
    echo "Username: $MYSQL_USER"
    echo "Password: $MYSQL_PASSWORD"
    echo "Root password: $MYSQL_ROOT_PASSWORD"
    echo
  fi
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
execute_command "docker compose cp ""${LAST_BACKUP_DIR}/${LAST_BACKUP_FILE}"" ""supportpal:${TEMP_BACKUP_DIR}/"""
TAR_EXTRACT_FLAGS=$(get_tar_flags "$LAST_BACKUP_FILE" "xv")
TAR_OUTPUT=$(docker compose exec supportpal bash -c "cd ${TEMP_BACKUP_DIR} && tar -${TAR_EXTRACT_FLAGS} ${LAST_BACKUP_FILE}")

# MYSQL_ENABLED=0 means an external database is used; skip the database restore and only restore the filesystem.
MYSQL_ENABLED="$(docker compose exec supportpal bash -c 'echo "${MYSQL_ENABLED:-1}"' | tr -d '[:space:]')"
if [[ "$MYSQL_ENABLED" = "1" ]]; then
  docker compose exec -u supportpal supportpal bash -c "cd ${COMMAND_PATH} && php artisan app:restore ${TEMP_BACKUP_DIR}/${LAST_BACKUP_FILE} --no-verify --force"
else
  FS_BACKUP_PATH="$(docker compose exec supportpal bash -c "ls ${TEMP_BACKUP_DIR}/filesystem-*.tar.gz 2>/dev/null | head -n1" | tr -d '[:space:]')"
  if [[ -z "$FS_BACKUP_PATH" ]]; then
    echo "error: could not find a filesystem-*.tar.gz archive inside ${LAST_BACKUP_FILE}"
    exit 1
  fi

  echo "warning: the bundled MySQL server is disabled (MYSQL_ENABLED=0), the database will not be restored"
  echo "hint: if necessary, restore your external database server independently of this script"

  docker compose exec -u supportpal supportpal bash -c "cd ${COMMAND_PATH} && php artisan filesystem:restore ${FS_BACKUP_PATH} --no-verify --force"
fi

# If backup generated via docker, restore volumes.
if grep -qs '^volumes-monolithic/$' <<< "${TAR_OUTPUT}"; then
  echo 'Restoring volume data...'

  docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/cache/redis-data /"
  docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/caddy/caddy /"
  if grep -qs '^volumes-monolithic/meilisearch' <<< "${TAR_OUTPUT}"; then
    docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/meilisearch/meilisearch /"
  fi
  if grep -qs '^volumes-monolithic/qdrant' <<< "${TAR_OUTPUT}"; then
    docker compose exec -u root supportpal bash -c "cp -r ${TEMP_BACKUP_DIR}/volumes-monolithic/qdrant/qdrant /"
  fi
  rm -rf "backup/${TIMESTAMP}/"
fi

echo "Restarting services..."
execute_command "docker compose down"
execute_command "docker compose up -d"

if [[ -n "${RESTORE_PATH+x}" ]]; then
  echo
  echo "Restored successfully to ${RESTORE_PATH}"

  rm -f "$RESTORE_PATH/$LAST_BACKUP_FILE"
fi
