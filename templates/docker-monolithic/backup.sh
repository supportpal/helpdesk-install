#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.
    --pre-upgrade              Create a rollback point for an upgrade rather than a full backup: the docker volumes
                               are copied to <volume>_pre_upgrade volumes and only the docker files are archived.
                               Roll back by passing the archive to restore.sh: --file backup/pre-upgrade-<timestamp>.tar.gz
    --portable                 Use the helpdesk's own backup format (a database dump and the application files),
                               written to backup/app-<timestamp>.tar, rather than copies of the docker volumes,
                               written to backup/volumes-<timestamp>.tar.gz. Slower, but can be restored on any
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
  echo "error: --pre-upgrade cannot be combined with --portable or --online"
  exit 1
fi

if $online && ! $portable; then
  echo "notice: --online implies --portable, as the docker volumes can only be copied while the container is stopped"
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

# The restore.sh that matches this script, for the rollback instructions.
RESTORE_SCRIPT_URL="https://raw.githubusercontent.com/supportpal/helpdesk-install/6.x/templates/docker-monolithic/restore.sh"

# Make sure that the script is executed in the directory where docker-compose.yml is.
if ! grep -q "container_name: supportpal" < <(docker compose config 2>/dev/null); then
    echo "error: the script must be executed in your SupportPal installation directory (where your docker-compose.yml file is)"
    exit 1
fi

# MYSQL_ENABLED=0 means an external database is used; the database is excluded from the backup.
MYSQL_ENABLED="$(docker compose exec supportpal bash -c 'echo "${MYSQL_ENABLED:-1}"' | tr -d '[:space:]')"
if [[ "${MYSQL_ENABLED}" != "1" ]]; then
  echo "warning: the bundled MySQL server is disabled (MYSQL_ENABLED=0), the database will not be included in the backup"
  echo "hint: backing up your external database server is your responsibility"
  echo
fi

# Volumes mounted at these paths are archived from the running container rather than copied while it is stopped:
# attachments are only ever added, and neither storage/ nor the logs are modified by an upgrade.
LIVE_MOUNTS="/var/www/supportpal/storage /var/log"
MYSQL_MOUNT="/var/lib/mysql"

# The MySQL clone plugin refuses to write inside the data directory (which is the whole of the volume at MYSQL_MOUNT),
# so the database is cloned to a scratch directory in the volume mounted here and copied from there. The logs are
# never copied by --pre-upgrade, so a directory left behind by an interrupted run cannot end up in a rollback point.
CLONE_MOUNT="/var/log"

# Volumes created by this script are labelled with the backup timestamp, so that it never removes a volume it did
# not create and restore.sh can check that a rollback point belongs to the archive being restored.
VOLUME_LABEL="com.supportpal.backup"

# Sets CONTAINER_IMAGE, SNAPSHOT_VOLUMES (copied while the container is stopped), LIVE_VOLUMES (archived from the
# running container), MYSQL_VOLUME and CLONE_VOLUME.
inspect_container() {
  local container_id name destination type source cwd

  container_id="$(docker compose ps -q supportpal)"
  if [[ -z "${container_id}" ]]; then
    echo "error: the supportpal container is not running"
    exit 1
  fi

  CONTAINER_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${container_id}")"

  SNAPSHOT_VOLUMES=""
  LIVE_VOLUMES=""
  MYSQL_VOLUME=""
  CLONE_VOLUME=""
  while read -r name destination; do
    [[ -n "${name}" ]] || continue
    if [[ " ${LIVE_MOUNTS} " == *" ${destination} "* ]]; then
      LIVE_VOLUMES+="${name}"$'\n'
    else
      SNAPSHOT_VOLUMES+="${name}"$'\n'
    fi
    if [[ "${destination}" == "${MYSQL_MOUNT}" ]]; then
      MYSQL_VOLUME="${name}"
    elif [[ "${destination}" == "${CLONE_MOUNT}" ]]; then
      CLONE_VOLUME="${name}"
    fi
  done < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{"\n"}}{{end}}{{end}}' "${container_id}")

  if [[ -z "${SNAPSHOT_VOLUMES}${LIVE_VOLUMES}" ]]; then
    echo "error: the supportpal container has no named docker volumes to copy"
    echo "hint: use --portable instead"
    exit 1
  fi

  # Only docker volumes are copied. Bind mounts of paths within the installation directory are archived with the
  # docker files; warn about any others (for example attachments on a separate disk) rather than skipping silently.
  cwd="$(realpath "$(pwd)")"
  while read -r type destination source; do
    [[ "${type}" == "bind" ]] || continue
    [[ "${source}" != "${cwd}" && "${source}" != "${cwd}/"* ]] || continue
    if $pre_upgrade; then
      echo "warning: ${destination} is bind mounted from ${source} on the host, it will not be copied to the rollback point or restored by a rollback"
    else
      echo "warning: ${destination} is bind mounted from ${source} on the host, it will not be included in the backup"
    fi
    echo "hint: back up ${source} yourself, this script only copies docker volumes"
  done < <(docker inspect --format '{{range .Mounts}}{{if ne .Type "volume"}}{{.Type}} {{.Destination}} {{.Source}}{{"\n"}}{{end}}{{end}}' "${container_id}")
}

# Removes the given volumes if they were created by this script. Refuses to continue if one exists that was not.
remove_volumes() {
  local volume

  for volume in "$@"; do
    docker volume inspect "${volume}" > /dev/null 2>&1 || continue
    if ! grep -q "\"${VOLUME_LABEL}\"" < <(docker volume inspect --format '{{json .Labels}}' "${volume}"); then
      echo "error: the ${volume} docker volume already exists and was not created by this script"
      echo "hint: remove or rename it and try again"
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

  if [[ -z "${CLONE_VOLUME}" ]]; then
    echo "notice: no docker volume is mounted at ${CLONE_MOUNT}, the database will be copied while the container is stopped"
    return 1
  fi

  # Remove anything left behind by an interrupted run, then create a directory that MySQL can write to. The clone
  # plugin creates the target directory itself, so it is given a subdirectory of it.
  if ! docker compose exec -T supportpal bash -c "
    sudo rm -rf ${CLONE_MOUNT}/.clone-* && sudo mkdir ${CLONE_MOUNT}/${dir} && sudo chown mysql:mysql ${CLONE_MOUNT}/${dir}
  " > /dev/null 2>&1; then
    echo "warning: failed to create ${CLONE_MOUNT}/${dir} in the container, the database will be copied while the container is stopped instead"
    return 1
  fi

  # The helpdesk's database user holds the BACKUP_ADMIN and CLONE_ADMIN grants. Exits 2 if the plugin is not active.
  docker compose exec -T -u supportpal supportpal php -- "${CLONE_MOUNT}/${dir}/data" <<'PHP' || status=$?
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
    echo "warning: the online database copy failed, the database will be copied while the container is stopped instead"
  else
    echo "Copying the database to ${target}..."
    copy_volume "${CLONE_VOLUME}" "${dir}/data" "${target}" || status=1
  fi

  docker compose exec -T supportpal bash -c "sudo rm -rf ${CLONE_MOUNT}/${dir}" > /dev/null 2>&1 || true
  return "${status}"
}

# Usage: abort_snapshot <volumes...>
# Removes the copies left behind by a failed or interrupted snapshot_volumes and starts the container again.
abort_snapshot() {
  echo
  echo "error: failed to copy the docker volumes"
  echo "Starting container..."
  docker compose start > /dev/null 2>&1 || true
  echo "Removing the partial copies..."
  remove_volumes "$@"
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

  # Remove the partial copies and start the container again if copying fails or is interrupted. An EXIT trap is
  # used as ERR traps do not fire for failures inside functions.
  # shellcheck disable=SC2064
  trap "abort_snapshot ${targets[*]}" EXIT
  trap 'exit 1' INT TERM HUP

  for volume in ${SNAPSHOT_VOLUMES}; do
    [[ "${volume}" != "${skip}" ]] || continue
    echo "Copying ${volume} to ${volume}${suffix}..."
    copy_volume "${volume}" "." "${volume}${suffix}"
  done

  trap - EXIT INT TERM HUP

  echo "Starting container..."
  execute_command "docker compose start"
}

# pigz compresses on all cores. Prefer it inside the helpdesk image, then on the host, then fall back to gzip.
# Sets CONTAINER_COMPRESSOR and HOST_COMPRESSOR; one compresses and the other passes the stream through.
select_compressor() {
  if docker compose exec -T supportpal sh -c 'command -v pigz' > /dev/null 2>&1; then
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
# disk space needed is the volume copies plus the archive itself. The archive is named volumes-<timestamp>.tar.gz,
# so that readers of the helpdesk's own app-* format (app:restore, older restore scripts) never select it.
#
# Archive layout (a single gzip stream):
#   manifest.txt              image and volume names; first, so restore.sh can read it without decompressing the rest
#   docker-files/             the current working directory
#   volumes/<volume name>/    the contents of each docker volume
volume_backup() {
  local archive="${ABS_BACKUP_PATH}/volumes-${TIMESTAMP}.tar.gz" volume manifest mounts=() copies=() status

  inspect_container
  select_compressor
  snapshot_volumes "_backup"

  manifest="format 1"$'\n'"image ${CONTAINER_IMAGE}"$'\n'
  for volume in ${SNAPSHOT_VOLUMES}; do
    manifest+="volume ${volume}"$'\n'
    mounts+=(-v "${volume}_backup:/volumes/${volume}:ro")
    copies+=("${volume}_backup")
  done
  for volume in ${LIVE_VOLUMES}; do
    manifest+="volume ${volume}"$'\n'
    mounts+=(-v "${volume}:/volumes/${volume}:ro")
  done

  # The archive is written under a temporary name and only renamed once it is complete, so that restore.sh never
  # selects a truncated one. Remove it and the volume copies if archiving fails or is interrupted.
  # shellcheck disable=SC2064
  trap "abort_volume_backup '${archive}.part' ${copies[*]}" EXIT
  trap 'exit 1' INT TERM HUP

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
    ' | "${HOST_COMPRESSOR}" > "${archive}.part"
  status=("${PIPESTATUS[@]}")
  set -e -o pipefail

  if [[ "${status[0]}" -eq 1 ]]; then
    echo "warning: some files changed while they were being archived"
  elif [[ "${status[0]}" -ne 0 || "${status[1]}" -ne 0 ]]; then
    echo "error: failed to create the backup"
    exit 1
  fi

  trap - EXIT INT TERM HUP

  remove_volumes "${copies[@]}"
  mv "${archive}.part" "${archive}"

  echo "Backup created successfully at ${archive}"
  echo
}

# Usage: abort_volume_backup <partial archive> <volume copies...>
# Removes the files left behind by a failed or interrupted volume backup.
abort_volume_backup() {
  echo
  echo "Removing temporary files..."
  rm -f "$1"
  shift
  remove_volumes "$@"
}

# Usage: rollback_command <timestamp>
# Prints the command that rolls back to the rollback point with the given timestamp. restore.sh is fetched from
# GitHub, as setup.sh does not put it in the installation directory.
rollback_command() {
  echo "bash <(curl -fLsS ${RESTORE_SCRIPT_URL}) --file ${BACKUP_DIR}/pre-upgrade-$1.tar.gz"
}

# Asks before replacing the volume copies from a previous --pre-upgrade run, as they may be the only way to roll
# back a failed upgrade. Exits unless the answer is Y: when called from upgrade.sh, this stops the upgrade.
confirm_replace_rollback_point() {
  local volume label existing=() timestamp=""

  # Volumes without the label were not created by this script; remove_volumes refuses to touch those.
  for volume in ${SNAPSHOT_VOLUMES}; do
    label="$(docker volume inspect --format "{{index .Labels \"${VOLUME_LABEL}\"}}" "${volume}_pre_upgrade" 2>/dev/null || true)"
    if [[ -n "${label}" ]]; then
      existing+=("${volume}_pre_upgrade")
      timestamp="${label}"
    fi
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    return
  fi

  echo "A rollback point from ${timestamp} already exists:"
  echo
  echo "    ${existing[*]}"
  echo
  echo "It will be replaced, after which ${BACKUP_DIR}/pre-upgrade-${timestamp}.tar.gz can no longer be used to roll back."
  echo "hint: if the previous upgrade failed, roll back to it first rather than replacing it:"
  echo "    $(rollback_command "${timestamp}")"
  echo "Do you want to proceed? [Y/n]"
  read -r PROCEED
  if [[ "${PROCEED}" != "Y" ]]; then
    echo "The existing rollback point has been kept."
    exit 1
  fi
  echo
}

# Creates a rollback point for an upgrade: the volume copies are kept and only the docker files are archived. The
# archive holds no application data, so it is named such that restore.sh never selects it by default.
pre_upgrade_backup() {
  local archive="${ABS_BACKUP_PATH}/pre-upgrade-${TIMESTAMP}.tar.gz" volume manifest_dir

  inspect_container
  confirm_replace_rollback_point
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
  echo "To roll back, run from this directory:"
  echo
  echo "    $(rollback_command "${TIMESTAMP}")"
  echo
  echo "Once you are satisfied with the upgrade, remove the rollback point to free the disk space:"
  echo
  echo "    docker volume rm $(for volume in ${SNAPSHOT_VOLUMES}; do printf '%s_pre_upgrade ' "${volume}"; done)"
  echo "    rm ${BACKUP_DIR}/pre-upgrade-${TIMESTAMP}.tar.gz"
  echo
}

# Stops every service except Redis and MySQL, so that the files and database do not change while they are backed up.
stop_services() {
  docker compose exec -T supportpal bash -c "
    sudo find -L /etc/service -maxdepth 1 -mindepth 1 -type d \
    ! -name 'redis' ! -name '00redis' ! -name 'mysql' ! -name '00mysql' \
    -printf '%f\n' -exec sv stop {} \; $(if [ "$debug" = false ]; then echo '> /dev/null 2>&1'; fi)
  "
}

start_services() {
  echo "Starting services..."
  execute_command "docker compose restart supportpal"
}

# Usage: archive_from_container <archive> <tar arguments...>
# Runs tar inside the container with the given arguments and streams its output into <archive>, compressed with
# pigz where available, so that nothing is copied to disk first. Prints a warning if files changed while they were
# being archived and exits on any other failure.
archive_from_container() {
  local archive="$1" status
  shift

  # tar exits 1 if a file changes while it is read. pipefail inside the container makes tar's status the exec's.
  set +e +o pipefail
  docker compose exec -T -u root -e COMPRESSOR="${CONTAINER_COMPRESSOR}" supportpal bash -c '
    set -o pipefail
    tar "$@" | "${COMPRESSOR}"
  ' bash "$@" | "${HOST_COMPRESSOR}" > "${archive}"
  status=("${PIPESTATUS[@]}")
  set -e -o pipefail

  if [[ "${status[0]}" -eq 1 ]]; then
    echo "warning: some files changed while they were being archived"
  elif [[ "${status[0]}" -ne 0 || "${status[1]}" -ne 0 ]]; then
    echo "error: failed to create $(basename "${archive}")"
    exit 1
  fi
}

# Usage: abort_portable_backup <tmp dir> <archive>
# Removes the files left behind by a failed or interrupted portable backup and starts the services again.
abort_portable_backup() {
  echo
  echo "Removing temporary files..."
  rm -rf "$1" "$2"
  if ! $online; then
    start_services
  fi
}

# Creates a backup in the helpdesk's own format, which app:restore can restore on any deployment type.
portable_backup() {
  local tmp_dir="${ABS_BACKUP_PATH}/tmp-${TIMESTAMP}" archive="${ABS_BACKUP_PATH}/app-${TIMESTAMP}.tar"
  local filesystem_backup_name="filesystem-${TIMESTAMP}.tar.gz"
  local command_path gte_v420 db_backup_path volume_dirs dir db_file_name=

  # Determine command path. Some commands moved to app-manager in v4.2.0
  gte_v420="$(docker compose exec supportpal php -r "\$release = require '/var/www/supportpal/config/release.php'; echo (int) version_compare(\$release['version'], '4.2.0', '>=');")"
  if [[ "$gte_v420" = "0" ]]; then command_path="/var/www/supportpal"; else command_path="/var/www/supportpal/app-manager"; fi

  select_compressor

  # Clean up and start the services again if the backup fails or is interrupted. An EXIT trap is used as ERR traps
  # do not fire for failures inside functions. The paths are expanded now as they are local to this function.
  # shellcheck disable=SC2064
  trap "abort_portable_backup '${tmp_dir}' '${archive}'" EXIT
  trap 'exit 1' INT TERM HUP

  if ! $online; then
    echo "Stopping services..."
    stop_services
  fi

  mkdir -p "${tmp_dir}"

  echo "Backing up filesystem, this may take a while..."
  archive_from_container "${tmp_dir}/${filesystem_backup_name}" \
    -C /var/www/supportpal --transform "s,^,filesystem-${TIMESTAMP}/,S" -cf - config/production storage addons

  if [[ "${MYSQL_ENABLED}" = "1" ]]; then
    echo 'Backing up database...'
    db_backup_path=$(docker compose exec -u supportpal supportpal bash -c "cd ${command_path} && php artisan db:backup --store-local | grep -oE '/var/www/supportpal/.*/database-.*'")
    db_file_name=$(echo "${db_backup_path}" | xargs basename)
    docker compose cp "supportpal:${db_backup_path}" "${tmp_dir}/" || { echo "error: failed to copy database backup from container"; exit 1; }
    docker compose exec supportpal bash -c "rm ${db_backup_path}"
  fi

  echo 'Backing up volume data...'
  volume_dirs=(redis-data caddy)
  for dir in meilisearch qdrant; do
    if docker compose exec -T -u root supportpal test -d "/${dir}"; then
      volume_dirs+=("${dir}")
    fi
  done
  archive_from_container "${tmp_dir}/volumes-monolithic.tar.gz" -C / -cf - "${volume_dirs[@]}"

  echo "Backing up current working directory: $(pwd)..."
  tar -czf "${tmp_dir}/docker-files.tar.gz" --exclude="./${BACKUP_DIR}" .

  echo "Combining into $(basename "${archive}")..."
  (cd "${tmp_dir}" && tar -cf "${archive}" "${filesystem_backup_name}" ${db_file_name:+"${db_file_name}"} volumes-monolithic.tar.gz docker-files.tar.gz)
  rm -rf "${tmp_dir}"

  trap - EXIT INT TERM HUP

  echo "Backup created successfully at ${archive}"
  echo

  if ! $online; then
    start_services
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
