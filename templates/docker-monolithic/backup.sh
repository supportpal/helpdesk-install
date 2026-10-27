#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.
    --pre-upgrade              Create a rollback point for an upgrade rather than a full backup: the docker volumes
                               are copied to <volume>_pre_upgrade volumes and only the docker files are archived.
                               Roll back with: bash restore.sh --file backup/pre-upgrade-<timestamp>.tar.gz
    --portable                 Use the helpdesk's own backup format (a database dump and the application files)
                               rather than copies of the docker volumes. Slower, but can be restored on any
                               deployment type or MySQL version.
    --online                   Do not stop the services. Implies --portable.
    --debug                    Enable verbose output.
"

# Options
pre_upgrade=false
portable=false
online=false
debug=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  --pre-upgrade) pre_upgrade=true ;;
  --portable) portable=true ;;
  --online) online=true ;;
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

if $pre_upgrade && { $portable || $online; }; then
  echo "error: --pre-upgrade cannot be combined with --portable or --online."
  exit 1
fi

if $online && ! $portable; then
  echo "[NOTICE]"
  echo "--online implies --portable, as the docker volumes can only be copied while the container is stopped."
  echo
  portable=true
fi

execute_command() {
    local cmd="$1"

    if [ "$debug" = false ]; then
        eval "$cmd > /dev/null 2>&1"
    else
        eval "$cmd"
    fi
}

BACKUP_DIR="backup"
ABS_BACKUP_PATH="$(pwd)/${BACKUP_DIR}"
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)

# Make sure that the script is executed in the directory where docker-compose.yml is.
if ! grep -q "container_name: supportpal" < <(docker compose config 2>/dev/null); then
    echo "error: the script must be executed in your SupportPal installation directory (where your docker-compose.yml file is)."
    exit 1
fi

echo "[NOTICE]"
echo "The backup includes all files in the current working directory ($(pwd))."
echo
echo "It is recommended to move your installation files (docker-compose.yml, docker-compose.override.yml, .env, etc) to"
echo "a separate directory, to avoid including unnecessary files in the backup."
echo

# MYSQL_ENABLED=0 means an external database is used; the database is excluded from the backup.
MYSQL_ENABLED="$(docker compose exec supportpal bash -c 'echo "${MYSQL_ENABLED:-1}"' | tr -d '[:space:]')"
if [[ "${MYSQL_ENABLED}" != "1" ]]; then
  echo "[WARNING]"
  echo "The bundled MySQL server is disabled (MYSQL_ENABLED=0). The database will NOT be included in this"
  echo "backup. Backing up your external database server is your responsibility."
  echo
fi

# Volumes mounted at these paths are archived from the running container rather than copied while it is stopped:
# attachments are only ever added, and neither storage/ nor the logs are modified by an upgrade.
LIVE_MOUNTS="/var/www/supportpal/storage /var/log"
MYSQL_MOUNT="/var/lib/mysql"

# Volumes created by this script are labelled with the backup timestamp, so that it never removes a volume it did
# not create and restore.sh can check that a rollback point belongs to the archive being restored.
VOLUME_LABEL="com.supportpal.backup"

# Sets CONTAINER_IMAGE, SNAPSHOT_VOLUMES (copied while the container is stopped), LIVE_VOLUMES (archived from the
# running container) and MYSQL_VOLUME.
inspect_container() {
  local container_id name destination

  container_id="$(docker compose ps -q supportpal)"
  if [[ -z "${container_id}" ]]; then
    echo "error: the supportpal container is not running."
    exit 1
  fi

  CONTAINER_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${container_id}")"

  SNAPSHOT_VOLUMES=""
  LIVE_VOLUMES=""
  MYSQL_VOLUME=""
  while read -r name destination; do
    [[ -n "${name}" ]] || continue
    if [[ " ${LIVE_MOUNTS} " == *" ${destination} "* ]]; then
      LIVE_VOLUMES+="${name}"$'\n'
    else
      SNAPSHOT_VOLUMES+="${name}"$'\n'
    fi
    if [[ "${destination}" == "${MYSQL_MOUNT}" ]]; then
      MYSQL_VOLUME="${name}"
    fi
  done < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{"\n"}}{{end}}{{end}}' "${container_id}")

  if [[ -z "${SNAPSHOT_VOLUMES}${LIVE_VOLUMES}" ]]; then
    echo "error: the supportpal container has no named docker volumes to copy. Use --portable instead."
    exit 1
  fi
}

# Removes the given volumes if they were created by this script. Refuses to continue if one exists that was not.
remove_volumes() {
  local volume

  for volume in "$@"; do
    docker volume inspect "${volume}" > /dev/null 2>&1 || continue
    if ! grep -q "\"${VOLUME_LABEL}\"" < <(docker volume inspect --format '{{json .Labels}}' "${volume}"); then
      echo "error: the ${volume} docker volume already exists and was not created by this script. Remove or rename it and try again."
      exit 1
    fi
    execute_command "docker volume rm ${volume}"
  done
}

# Usage: copy_volume <source volume> <path within it> <target volume>
# Copies as root to preserve ownership, using the helpdesk image as it is already present and ships GNU cp.
# --init lets Ctrl+C stop the copy, which cp would otherwise ignore as PID 1.
copy_volume() {
  local source="$1" path="$2" target="$3"

  execute_command "docker volume create --label ${VOLUME_LABEL}=${TIMESTAMP} ${target}"

  docker run --rm --init -u root --entrypoint cp \
    -v "${source}:/from:ro" \
    -v "${target}:/to" \
    "${CONTAINER_IMAGE}" -a --reflink=auto "/from/${path}/." /to/
}

# Copies the database to the given volume while MySQL keeps running, using the MySQL clone plugin (bundled with
# the helpdesk image from SupportPal 6.2.0). Returns non-zero if the plugin is unavailable or the clone fails.
clone_database() {
  local target="$1" dir=".clone-${TIMESTAMP}" status=0

  # Remove anything left behind by an interrupted run.
  docker compose exec -T supportpal bash -c "sudo rm -rf ${MYSQL_MOUNT}/.clone-*" > /dev/null 2>&1 || true

  # The helpdesk's database user holds the BACKUP_ADMIN and CLONE_ADMIN grants. Exits 2 if the plugin is not active.
  docker compose exec -T -u supportpal supportpal php -- "${MYSQL_MOUNT}/${dir}" <<'PHP' || status=$?
<?php
$config = require '/var/www/supportpal/config/production/database.php';
$connection = $config['connections']['mysql'];

$dsn = 'mysql:host=' . $connection['host'] . ';port=' . ($connection['port'] ?? 3306);
$pdo = new PDO($dsn, $connection['username'], $connection['password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);

if ($pdo->query("SELECT plugin_status FROM information_schema.plugins WHERE plugin_name = 'clone'")->fetchColumn() !== 'ACTIVE') {
    exit(2);
}

echo "Copying the database online using the MySQL clone plugin...\n";
$pdo->exec('CLONE LOCAL DATA DIRECTORY = ' . $pdo->quote($argv[1]));
PHP

  if [[ "${status}" -eq 2 ]]; then
    echo "The MySQL clone plugin is not available (SupportPal 6.2.0 or later), the database will be copied while the container is stopped."
  elif [[ "${status}" -ne 0 ]]; then
    echo "warning: the online database copy failed, the database will be copied while the container is stopped instead."
  else
    echo "Copying the database to ${target}..."
    copy_volume "${MYSQL_VOLUME}" "${dir}" "${target}" || status=1
  fi

  docker compose exec -T supportpal bash -c "sudo rm -rf ${MYSQL_MOUNT}/${dir}" > /dev/null 2>&1 || true
  return "${status}"
}

# Copies each of SNAPSHOT_VOLUMES to <volume><suffix>. The database is copied online where possible; everything
# else is copied while the container is stopped, so that it is consistent on disk. The copies are plain copies on
# the host filesystem (reflink copies where the filesystem supports it).
snapshot_volumes() {
  local suffix="$1" volume skip="" targets=()

  # Replace the copies from a previous run before touching the container.
  for volume in ${SNAPSHOT_VOLUMES}; do
    targets+=("${volume}${suffix}")
  done
  remove_volumes "${targets[@]}"

  if [[ -n "${MYSQL_VOLUME}" && "${MYSQL_ENABLED}" = "1" ]] && clone_database "${MYSQL_VOLUME}${suffix}"; then
    skip="${MYSQL_VOLUME}"
  fi

  echo "Stopping container..."
  execute_command "docker compose stop"

  # Start the container again if copying fails or is interrupted. An EXIT trap is used as ERR traps do not fire
  # for failures inside functions.
  trap 'echo; echo "error: failed to copy the docker volumes, starting container..."; docker compose start > /dev/null 2>&1' EXIT
  trap 'exit 1' INT TERM

  for volume in ${SNAPSHOT_VOLUMES}; do
    [[ "${volume}" != "${skip}" ]] || continue
    echo "Copying ${volume} to ${volume}${suffix}..."
    copy_volume "${volume}" "." "${volume}${suffix}"
  done

  trap - EXIT INT TERM

  echo "Starting container..."
  execute_command "docker compose start"
}

# pigz compresses on all cores. Prefer it inside the helpdesk image, then on the host, then fall back to gzip.
# Sets CONTAINER_COMPRESSOR and HOST_COMPRESSOR; one compresses and the other passes the stream through.
select_compressor() {
  if docker run --rm --entrypoint sh "${CONTAINER_IMAGE}" -c 'command -v pigz' > /dev/null 2>&1; then
    CONTAINER_COMPRESSOR="pigz"
    HOST_COMPRESSOR="cat"
  elif command -v pigz > /dev/null 2>&1; then
    CONTAINER_COMPRESSOR="cat"
    HOST_COMPRESSOR="pigz"
  else
    CONTAINER_COMPRESSOR="gzip"
    HOST_COMPRESSOR="cat"
  fi
}

# Default. Copies the volumes (see snapshot_volumes), then archives the copies and the live volumes while the
# helpdesk is running. Everything is streamed from one helper container straight into the archive, so the only
# disk space needed is the volume copies plus the archive itself.
#
# Archive layout (a single gzip stream):
#   manifest.txt              image and volume names; first, so restore.sh can read it without decompressing the rest
#   docker-files/             the current working directory
#   volumes/<volume name>/    the contents of each docker volume
volume_backup() {
  local archive="${ABS_BACKUP_PATH}/app-${TIMESTAMP}.tar.gz" volume manifest mounts=() status

  inspect_container
  select_compressor
  snapshot_volumes "_backup"

  manifest="format 1"$'\n'"image ${CONTAINER_IMAGE}"$'\n'
  for volume in ${SNAPSHOT_VOLUMES}; do
    manifest+="volume ${volume}"$'\n'
    mounts+=(-v "${volume}_backup:/volumes/${volume}:ro")
  done
  for volume in ${LIVE_VOLUMES}; do
    manifest+="volume ${volume}"$'\n'
    mounts+=(-v "${volume}:/volumes/${volume}:ro")
  done

  echo "Archiving to ${archive}, this may take a while..."

  # tar exits 1 if a live volume changes while it is read, which is harmless here (attachments added or removed
  # after the database was copied). pipefail inside the container makes tar's status the container's.
  set +e +o pipefail
  docker run --rm --init -u root --entrypoint bash \
    -e MANIFEST="${manifest}" \
    -e BACKUP_DIR="${BACKUP_DIR}" \
    -e COMPRESSOR="${CONTAINER_COMPRESSOR}" \
    -v "$(pwd):/docker-files:ro" \
    "${mounts[@]}" \
    "${CONTAINER_IMAGE}" -c '
      set -o pipefail
      printf "%s" "${MANIFEST}" > /manifest.txt
      tar -C / --anchored --exclude="docker-files/${BACKUP_DIR}" -cf - manifest.txt docker-files volumes | "${COMPRESSOR}"
    ' | "${HOST_COMPRESSOR}" > "${archive}"
  status=("${PIPESTATUS[@]}")
  set -e -o pipefail

  for volume in ${SNAPSHOT_VOLUMES}; do
    execute_command "docker volume rm ${volume}_backup"
  done

  if [[ "${status[0]}" -eq 1 ]]; then
    echo "warning: some files changed while they were being archived."
  elif [[ "${status[0]}" -ne 0 || "${status[1]}" -ne 0 ]]; then
    rm -f "${archive}"
    echo "error: failed to create the backup."
    exit 1
  fi

  echo "Backup created successfully at ${archive}"
  echo
}

# Creates a rollback point for an upgrade: the volume copies are kept and only the docker files are archived. The
# archive holds no application data, so it is named such that restore.sh never selects it by default.
pre_upgrade_backup() {
  local archive="${ABS_BACKUP_PATH}/pre-upgrade-${TIMESTAMP}.tar.gz" volume manifest_dir

  inspect_container
  snapshot_volumes "_pre_upgrade"

  # Record which volumes were copied, so that restore.sh can check they are all still present and from this run.
  manifest_dir="$(mktemp -d)"
  {
    echo "timestamp ${TIMESTAMP}"
    for volume in ${SNAPSHOT_VOLUMES}; do
      echo "volume ${volume}"
    done
  } > "${manifest_dir}/pre-upgrade-manifest.txt"

  echo "Backing up current working directory: $(pwd)..."
  tar -czf "${archive}" --exclude="./${BACKUP_DIR}" . -C "${manifest_dir}" pre-upgrade-manifest.txt
  rm -rf "${manifest_dir}"

  echo
  echo "Rollback point created successfully at ${archive}"
  echo
  echo "The application data is held in the following docker volumes (storage/ and the logs are not modified by an upgrade and have not been copied):"
  for volume in ${SNAPSHOT_VOLUMES}; do
    echo "    ${volume}_pre_upgrade"
  done
  echo
  echo "To roll back, run from this directory:"
  echo
  echo "    bash restore.sh --file ${BACKUP_DIR}/pre-upgrade-${TIMESTAMP}.tar.gz"
  echo
  echo "Once you are satisfied with the upgrade, free the disk space with:"
  echo
  echo "    docker volume rm $(for volume in ${SNAPSHOT_VOLUMES}; do printf '%s_pre_upgrade ' "${volume}"; done)"
  echo
}

# Creates a backup in the helpdesk's own format, which app:restore can restore on any deployment type.
portable_backup() {
  local tmp_dir="${ABS_BACKUP_PATH}/tmp-${TIMESTAMP}"
  local filesystem_backup_name="filesystem-${TIMESTAMP}.tar.gz" app_backup_name="app-${TIMESTAMP}.tar.gz"
  local command_path gte_v420 db_backup_path db_file_name=

  # Determine command path. Some commands moved to app-manager in v4.2.0
  gte_v420="$(docker compose exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
  if [[ "$gte_v420" = "0" ]]; then command_path="/var/www/supportpal"; else command_path="/var/www/supportpal/app-manager"; fi

  if ! $online; then
    echo "Stopping services..."
    docker compose exec supportpal bash -c "
      sudo find -L /etc/service -maxdepth 1 -mindepth 1 -type d \
      ! -name 'redis' ! -name '00redis' ! -name 'mysql' ! -name '00mysql' \
      -printf '%f\n' -exec sv stop {} \; $(if [ "$debug" = false ]; then echo '> /dev/null 2>&1'; fi)
    "
  fi

  echo 'Backing up filesystem...'
  mkdir -p "${tmp_dir}/filesystem-${TIMESTAMP}/config"
  docker compose cp supportpal:/var/www/supportpal/config/production "${tmp_dir}/filesystem-${TIMESTAMP}/config/" || { echo "error: failed to copy config/production from container"; exit 1; }
  docker compose cp supportpal:/var/www/supportpal/storage "${tmp_dir}/filesystem-${TIMESTAMP}/" || { echo "error: failed to copy storage from container"; exit 1; }
  docker compose cp supportpal:/var/www/supportpal/addons "${tmp_dir}/filesystem-${TIMESTAMP}/" || { echo "error: failed to copy addons from container"; exit 1; }
  (cd "${tmp_dir}" && tar -czf "${filesystem_backup_name}" "filesystem-${TIMESTAMP}" && rm -rf "filesystem-${TIMESTAMP}")

  if [[ "${MYSQL_ENABLED}" = "1" ]]; then
    echo 'Backing up database...'
    db_backup_path=$(docker compose exec -u supportpal supportpal bash -c "cd ${command_path} && php artisan db:backup --store-local | grep -oE '/var/www/supportpal/.*/database-.*'")
    db_file_name=$(echo "${db_backup_path}" | xargs basename)
    docker compose cp "supportpal:${db_backup_path}" "${tmp_dir}/" || { echo "error: failed to copy database backup from container"; exit 1; }
    docker compose exec supportpal bash -c "rm ${db_backup_path}"
  fi

  echo 'Backing up volume data...'
  mkdir -p "${tmp_dir}/volumes-monolithic/cache"
  mkdir -p "${tmp_dir}/volumes-monolithic/caddy"
  docker compose cp supportpal:/redis-data "${tmp_dir}/volumes-monolithic/cache/" || { echo "error: failed to copy redis-data from container"; exit 1; }
  docker compose cp supportpal:/caddy "${tmp_dir}/volumes-monolithic/caddy/" || { echo "error: failed to copy caddy from container"; exit 1; }
  if docker compose exec -u root supportpal bash -c "test -d /meilisearch"; then
    mkdir -p "${tmp_dir}/volumes-monolithic/meilisearch"
    docker compose cp supportpal:/meilisearch "${tmp_dir}/volumes-monolithic/meilisearch/" || { echo "error: failed to copy meilisearch from container"; exit 1; }
  fi
  if docker compose exec -u root supportpal bash -c "test -d /qdrant"; then
    mkdir -p "${tmp_dir}/volumes-monolithic/qdrant"
    docker compose cp supportpal:/qdrant "${tmp_dir}/volumes-monolithic/qdrant/" || { echo "error: failed to copy qdrant from container"; exit 1; }
  fi

  echo "Backing up current working directory: $(pwd)..."
  tar -czf "${tmp_dir}/docker-files.tar.gz" --exclude="./${BACKUP_DIR}" .

  # Combine backup files.
  (cd "${tmp_dir}" && tar -czf "${ABS_BACKUP_PATH}/${app_backup_name}" "${filesystem_backup_name}" ${db_file_name:+"${db_file_name}"} volumes-monolithic/ docker-files.tar.gz)
  rm -rf "${tmp_dir}"

  echo "Backup created successfully at ${ABS_BACKUP_PATH}/${app_backup_name}"
  echo

  if ! $online; then
    echo "Restarting services..."
    execute_command "docker compose restart supportpal"
  fi
}

mkdir -p "${ABS_BACKUP_PATH}/"

if $pre_upgrade; then
  pre_upgrade_backup
elif $portable; then
  portable_backup
else
  volume_backup
fi
