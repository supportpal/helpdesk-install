#!/bin/bash
set -eu -o pipefail

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
        echo "ERROR: Failed to stop Meilisearch service" >&2
        exit 1
    fi
    echo "✓ Meilisearch service stopped"

    # Clear Meilisearch database directory (including hidden files)
    echo "Clearing Meilisearch database directory..."
    if ! docker compose exec supportpal bash -c 'source <(sudo cat /etc/container_environment.sh) && rm -rf "${MEILI_DB_PATH:?}"/* "${MEILI_DB_PATH:?}"/.[!.]*'; then
        echo "ERROR: Failed to clear Meilisearch database directory" >&2
        exit 1
    fi
    echo "✓ Meilisearch database directory cleared"
}

# Helper function to parse version from meilisearch --version output
parse_meilisearch_version() {
    local version_output="$1"
    local pkgVersion

    echo "DEBUG: Raw version output: $version_output" >&2

    # Extract version number from output like "meilisearch 1.10.3"
    if ! pkgVersion="$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; then
        echo "ERROR: Failed to parse version from meilisearch --version output" >&2
        echo "DEBUG: Expected format: 'meilisearch x.y.z'" >&2
        echo "DEBUG: Actual output: $version_output" >&2
        exit 1
    fi

    echo "DEBUG: Extracted Meilisearch version: $pkgVersion" >&2
    echo "$pkgVersion"
}

# Usage: get_current_meilisearch_version <container_id>
get_current_meilisearch_version() {
    local CID="$1"
    local version

    echo "DEBUG: Getting Meilisearch version from container: $CID" >&2

    # Get version directly using meilisearch --version command
    if ! version="$(docker exec "$CID" meilisearch --version 2>&1)"; then
        echo "ERROR: Failed to get Meilisearch version from container $CID" >&2
        echo "DEBUG: Make sure the container is running and has meilisearch binary" >&2
        echo "DEBUG: Container logs:" >&2
        docker logs --tail 10 "$CID" >&2 || true
        exit 1
    fi

    parse_meilisearch_version "$version"
}

get_next_meilisearch_version() {
    echo "DEBUG: Fetching next Meilisearch version from docker-compose file..." >&2
    echo "DEBUG: Download URL: $COMPOSE_FILE_DOWNLOAD_URL" >&2

    local IMAGE
    if ! IMAGE=$(curl -fsSL "${COMPOSE_FILE_DOWNLOAD_URL}" 2>&1 | grep -m1 -E '^[[:space:]]*image:' | sed -E "s/^[[:space:]]*image:[[:space:]]*//; s/^['\"]//; s/['\"]$//"); then
        echo "ERROR: Failed to fetch or parse docker-compose file" >&2
        echo "DEBUG: URL: $COMPOSE_FILE_DOWNLOAD_URL" >&2
        echo "DEBUG: Check if the URL is accessible and contains valid YAML" >&2
        exit 1
    fi

    if [ -z "$IMAGE" ]; then
        echo "ERROR: Could not extract image name from docker-compose file" >&2
        echo "DEBUG: Expected to find a line like 'image: supportpal/helpdesk:latest'" >&2
        exit 1
    fi

    echo "DEBUG: Found image: $IMAGE" >&2

    # Get version directly using meilisearch --version without starting the full container
    echo "DEBUG: Getting Meilisearch version from image..." >&2

    local version
    if ! version="$(docker run --rm --entrypoint meilisearch "$IMAGE" --version 2>&1)"; then
        echo "ERROR: Failed to get Meilisearch version from image: $IMAGE" >&2
        echo "DEBUG: Check if the image exists and contains meilisearch binary" >&2
        echo "DEBUG: Docker run output: $version" >&2
        exit 1
    fi

    parse_meilisearch_version "$version"
}

# Check if a version requires data dumping for upgrade
meili_requires_upgrade() {
    local MEILISEARCH_DUMPLESS_VERSION="1.12.0"
    local from_version="$1"
    local to_version="$2"

    echo "DEBUG: Checking if Meilisearch requires upgrading" >&2
    echo "DEBUG: Current version: $from_version" >&2
    echo "DEBUG: Target version: $to_version" >&2
    echo "DEBUG: Dumpless version threshold: $MEILISEARCH_DUMPLESS_VERSION" >&2

    # Validate input versions
    if [ -z "$from_version" ] || [ -z "$to_version" ]; then
        echo "ERROR: Both from_version and to_version must be provided" >&2
        echo "DEBUG: from_version='$from_version', to_version='$to_version'" >&2
        exit 1
    fi

    # Check if versions are equal - no dump needed if not upgrading
    if [ "$from_version" = "$to_version" ]; then
        echo "DEBUG: No dump required - versions are identical (no upgrade needed)" >&2
        return 1  # false - no dump required
    fi

    # Check version format (basic validation)
    if ! echo "$from_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "WARNING: from_version '$from_version' doesn't match expected format (x.y.z)" >&2
    fi

    if ! echo "$to_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
        echo "WARNING: to_version '$to_version' doesn't match expected format (x.y.z)" >&2
    fi

    # If upgrading from < 1.12.0 to any version, dump is required
    local comparison_result
    comparison_result="$(printf '%s\n' "$from_version" "$MEILISEARCH_DUMPLESS_VERSION" | sort -V | head -n1)"

    if [ "$comparison_result" = "$from_version" ] && [ "$from_version" != "$MEILISEARCH_DUMPLESS_VERSION" ]; then
        echo "DEBUG: Upgrading from pre-$MEILISEARCH_DUMPLESS_VERSION version" >&2
        return 0  # true - dump required
    else
        echo "DEBUG: No dump required - version $from_version >= $MEILISEARCH_DUMPLESS_VERSION" >&2
        return 1  # false - no dump required
    fi
}

upgrade() {
    echo "Starting upgrade process..."

    # Get current Meilisearch version with error handling
    echo "Checking current Meilisearch version..."
    local current_container_id
    if ! current_container_id=$(docker compose ps -q supportpal 2>/dev/null); then
        echo "ERROR: Failed to get supportpal container ID" >&2
        echo "DEBUG: Ensure docker compose is running and supportpal service exists" >&2
        exit 1
    fi

    if [ -z "$current_container_id" ]; then
        echo "ERROR: supportpal container is not running" >&2
        echo "DEBUG: Start the containers with: docker compose up -d" >&2
        exit 1
    fi

    echo "DEBUG: Found supportpal container: $current_container_id" >&2

    local current_meili_version
    if ! current_meili_version="$(get_current_meilisearch_version "$current_container_id")"; then
        echo "ERROR: Failed to get current Meilisearch version" >&2
        echo "DEBUG: Check if Meilisearch is properly configured in the supportpal container" >&2
        exit 1
    fi

    echo "✓ Current Meilisearch version: $current_meili_version"

    # Get next Meilisearch version with error handling
    echo "Checking target Meilisearch version..."
    local next_meili_version
    if ! next_meili_version="$(get_next_meilisearch_version)"; then
        echo "ERROR: Failed to get target Meilisearch version" >&2
        echo "DEBUG: Check network connectivity and docker image availability" >&2
        exit 1
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
        echo "ERROR: Failed to stop containers" >&2
        echo "DEBUG: Check docker compose status and try manually: docker compose down -v" >&2
        exit 1
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
        echo "ERROR: Failed to start upgraded containers" >&2
        echo "DEBUG: Check docker compose logs: docker compose logs" >&2
        exit 1
    fi

    echo "Running helpdesk upgrade script..."
    if ! docker compose exec supportpal bash -c "bash /init/upgrade-helpdesk.sh"; then
        echo "ERROR: Helpdesk upgrade script failed" >&2
        echo "DEBUG: Check container logs: docker compose logs supportpal" >&2
        exit 1
    fi

    echo
    echo "✓ Upgrade complete!"
}

check_docker_compose
backup
upgrade
