#!/bin/bash
set -eu -o pipefail

# Generate unique log filename
generate_log_filename() {
    local base_name="upgrade"
    local ext="log"
    local filename="${base_name}.${ext}"
    local counter=1

    while [ -f "$filename" ]; do
        filename="${base_name}-${counter}.${ext}"
        ((counter++))
    done

    echo "$filename"
}

# Initialize log file
LOG_FILE="$(generate_log_filename)"
touch "$LOG_FILE"

# Log function - writes to log file
log_debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Error exit function - notifies user about log file
error_exit() {
    echo "ERROR: $1" >&2
    echo "A debug log is available in: $LOG_FILE"
    exit 1
}

usage="Options:
    -h,--help                  Display this help and exit.
    -r,--ref=5.x               Git ref (commit sha, ref name, tag) to run the script on.
    --skip-backup              Skip taking a backup before upgrading.
    --only-files               Only update the docker-compose files. Subsequent upgrade steps are skipped.
"

# options
ref=5.x
skip_backup=false
only_files=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
    -h | --help)
        echo "$usage"
        exit 0
        ;;
    -r | --ref)
        ref="$2"
        shift
        ;;
    --skip-backup)
        skip_backup=true
        ;;
    --only-files)
        only_files=true
        ;;
    *)
        echo "Unknown parameter passed: $1"
        exit 1
        ;;
    esac
    shift
done

COMPOSE_FILE_DOWNLOAD_URL="https://raw.githubusercontent.com/supportpal/helpdesk-install/${ref}/templates/docker-monolithic/docker-compose.yml"

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
    printf "checking docker compose version %s >= %s ... " "$version" "$min"
    version_ge "$version" "$min"
    printf "✔\n"
}

backup() {
    if [ "${skip_backup}" = true ]; then
        return
    fi

    echo
    echo "It is recommend to take a backup before upgrading, this may take some time. If you've already taken a backup you can skip this step."
    echo "Do you want to take a backup? [Y/n]"
    read -r PROCEED
    if [ "${PROCEED}" == "n" ] ; then
        return
    fi

    bash <(curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/5.x/templates/docker-monolithic/backup.sh)
}

update_compose_files() {
    curl -fLsS "${COMPOSE_FILE_DOWNLOAD_URL}" -o docker-compose.yml
}

update_volumes() {
    bash <(curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/"${ref}"/templates/docker-monolithic/create_volumes.sh)
}

migrate_hostname() {
    if [ ! -f docker-compose.override.yml ]; then
        return
    fi

    grep "hostname" docker-compose.override.yml | xargs | sed "s/hostname: /DOMAIN_NAME=/" >>.env
    if [[ "$(uname -s)" == Darwin ]]; then
        sed -i "" -e "s/hostname:.*/hostname: ''/" docker-compose.override.yml
    else
        sed -i -e "s/hostname:.*/hostname: ''/" docker-compose.override.yml
    fi
}

update_env() {
    if ! grep -qs 'DOMAIN_NAME=' .env; then
        migrate_hostname
    fi
}

drop_meilisearch_data() {
    echo "Preparing Meilisearch for upgrade..."

    # Stop Meilisearch service
    echo "Stopping Meilisearch service..."
    if ! docker compose exec supportpal sv stop 00meilisearch; then
        error_exit "Failed to stop Meilisearch service"
    fi
    echo "✓ Meilisearch service stopped"

    # Clear Meilisearch database directory (including hidden files)
    echo "Clearing Meilisearch database directory..."
    if ! docker compose exec supportpal bash -c 'source <(sudo cat /etc/container_environment.sh) && rm -rf "${MEILI_DB_PATH:?}"/* "${MEILI_DB_PATH:?}"/.[!.]*'; then
        error_exit "Failed to clear Meilisearch database directory"
    fi
    echo "✓ Meilisearch database directory cleared"
}

# Helper function to parse version from meilisearch --version output
parse_meilisearch_version() {
    local version_output="$1"
    local pkgVersion

    log_debug "Raw version output: $version_output"

    # Extract version number from output like "meilisearch 1.10.3"
    if ! pkgVersion="$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; then
        log_debug "Expected format: 'meilisearch x.y.z'"
        log_debug "Actual output: $version_output"
        error_exit "Failed to parse version from meilisearch --version output"
    fi

    log_debug "Extracted Meilisearch version: $pkgVersion"
    echo "$pkgVersion"
}

# Usage: get_current_meilisearch_version <container_id>
get_current_meilisearch_version() {
    local CID="$1"
    local version

    log_debug "Getting Meilisearch version from container: $CID"

    # Get version directly using meilisearch --version command
    if ! version="$(docker exec "$CID" meilisearch --version 2>&1)"; then
        log_debug "Make sure the container is running and has meilisearch binary"
        log_debug "Container logs:"
        docker logs --tail 10 "$CID" >> "$LOG_FILE" 2>&1 || true
        error_exit "Failed to get Meilisearch version from container $CID"
    fi

    parse_meilisearch_version "$version"
}

get_next_meilisearch_version() {
    log_debug "Fetching next Meilisearch version from docker-compose file..."
    log_debug "Download URL: $COMPOSE_FILE_DOWNLOAD_URL"

    local IMAGE
    if ! IMAGE=$(curl -fsSL "${COMPOSE_FILE_DOWNLOAD_URL}" 2>&1 | grep -m1 -E '^[[:space:]]*image:' | sed -E "s/^[[:space:]]*image:[[:space:]]*//; s/^['\"]//; s/['\"]$//"); then
        log_debug "URL: $COMPOSE_FILE_DOWNLOAD_URL"
        log_debug "Check if the URL is accessible and contains valid YAML"
        error_exit "Failed to fetch or parse docker-compose file"
    fi

    if [ -z "$IMAGE" ]; then
        log_debug "Expected to find a line like 'image: supportpal/helpdesk:latest'"
        error_exit "Could not extract image name from docker-compose file"
    fi

    log_debug "Found image: $IMAGE"

    # Get version directly using meilisearch --version without starting the full container
    log_debug "Getting Meilisearch version from image..."

    local version
    if ! version="$(docker run --rm --entrypoint meilisearch "$IMAGE" --version 2>&1)"; then
        log_debug "Check if the image exists and contains meilisearch binary"
        log_debug "Docker run output: $version"
        error_exit "Failed to get Meilisearch version from image: $IMAGE"
    fi

    parse_meilisearch_version "$version"
}

# Check if a version requires data dumping for upgrade
meili_requires_upgrade() {
    local MEILISEARCH_DUMPLESS_VERSION="1.12.0"
    local from_version="$1"
    local to_version="$2"

    log_debug "Checking if Meilisearch requires upgrading"
    log_debug "Current version: $from_version"
    log_debug "Target version: $to_version"
    log_debug "Dumpless version threshold: $MEILISEARCH_DUMPLESS_VERSION"

    # Validate input versions
    if [ -z "$from_version" ] || [ -z "$to_version" ]; then
        log_debug "from_version='$from_version', to_version='$to_version'"
        error_exit "Both from_version and to_version must be provided"
    fi

    # Check if versions are equal - no dump needed if not upgrading
    if [ "$from_version" = "$to_version" ]; then
        log_debug "No dump required - versions are identical (no upgrade needed)"
        return 1  # false - no dump required
    fi

    # Check version format (basic validation)
    if ! echo "$from_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
        log_debug "WARNING: from_version '$from_version' doesn't match expected format (x.y.z)"
    fi

    if ! echo "$to_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
        log_debug "WARNING: to_version '$to_version' doesn't match expected format (x.y.z)"
    fi

    # If upgrading from < 1.12.0 to any version, dump is required
    local comparison_result
    comparison_result="$(printf '%s\n' "$from_version" "$MEILISEARCH_DUMPLESS_VERSION" | sort -V | head -n1)"

    if [ "$comparison_result" = "$from_version" ] && [ "$from_version" != "$MEILISEARCH_DUMPLESS_VERSION" ]; then
        log_debug "Upgrading from pre-$MEILISEARCH_DUMPLESS_VERSION version"
        return 0  # true - dump required
    else
        log_debug "No dump required - version $from_version >= $MEILISEARCH_DUMPLESS_VERSION"
        return 1  # false - no dump required
    fi
}

upgrade() {
    echo "Starting upgrade process..."

    # Get current Meilisearch version with error handling
    echo "Checking current Meilisearch version..."
    local current_container_id
    if ! current_container_id=$(docker compose ps -q supportpal 2>/dev/null); then
        log_debug "Ensure docker compose is running and supportpal service exists"
        error_exit "Failed to get supportpal container ID"
    fi

    if [ -z "$current_container_id" ]; then
        log_debug "Start the containers with: docker compose up -d"
        error_exit "supportpal container is not running"
    fi

    log_debug "Found supportpal container: $current_container_id"

    local current_meili_version
    if ! current_meili_version="$(get_current_meilisearch_version "$current_container_id")"; then
        log_debug "Check if Meilisearch is properly configured in the supportpal container"
        error_exit "Failed to get current Meilisearch version"
    fi

    echo "✓ Current Meilisearch version: $current_meili_version"

    # Get next Meilisearch version with error handling
    echo "Checking target Meilisearch version..."
    local next_meili_version
    if ! next_meili_version="$(get_next_meilisearch_version)"; then
        log_debug "Check network connectivity and docker image availability"
        error_exit "Failed to get target Meilisearch version"
    fi

    echo "✓ Target Meilisearch version: $next_meili_version"

    # Check if dump is required
    if meili_requires_upgrade "$current_meili_version" "$next_meili_version"; then
        echo "✓ Meilisearch upgrade is required."
        echo "! The Meilisearch database will be dropped and re-indexed... cancel (CTRL+C) if you're not happy to proceed..."
        sleep 5
        drop_meilisearch_data
    fi

    echo "Stopping containers..."
    if ! docker compose down -v; then
        log_debug "Check docker compose status and try manually: docker compose down -v"
        error_exit "Failed to stop containers"
    fi

    echo "Updating volumes..."
    update_volumes

    echo "Updating environment configuration..."
    update_env

    echo "Updating docker-compose files..."
    update_compose_files

    if [ "${only_files}" = true ]; then
        echo "✓ Files updated successfully (--only-files specified)"
        exit 0
    fi

    echo "Starting upgraded containers..."
    if ! COMPOSE_PARALLEL_LIMIT=1 docker compose up -d; then
        log_debug "Check docker compose logs: docker compose logs"
        error_exit "Failed to start upgraded containers"
    fi

    echo "Running helpdesk upgrade script..."
    if ! docker compose exec supportpal bash -c "bash /init/upgrade-helpdesk.sh"; then
        log_debug "Check container logs: docker compose logs supportpal"
        error_exit "Helpdesk upgrade script failed"
    fi

    echo
    echo "✓ Upgrade complete!"
}

check_docker_compose
backup
upgrade
