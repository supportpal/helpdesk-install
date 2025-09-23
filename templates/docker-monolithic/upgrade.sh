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

COMPOSE_FILE_DOWNLOAD_URL="https://raw.githubusercontent.com/supportpal/helpdesk-install/"${ref}"/templates/docker-monolithic/docker-compose.yml"

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

create_meilisearch_dump_pre_upgrade() {
    local MASTER_KEY BASE_URL dump_response task_uid task_status
    local health_check_timeout=60 dump_timeout=300 retry_count=0 max_retries=30

    echo "Creating Meilisearch data dump with current version before upgrade..."

    # Get Meilisearch configuration with error handling
    echo "Retrieving Meilisearch configuration..."
    if ! MASTER_KEY="$(docker compose exec supportpal bash -c 'source <(sudo cat /etc/container_environment.sh) && echo $MEILI_MASTER_KEY' 2>/dev/null)"; then
        echo "ERROR: Failed to retrieve Meilisearch master key from container" >&2
        echo "DEBUG: Ensure the supportpal container is running and environment variables are properly set" >&2
        exit 1
    fi

    if ! BASE_URL="$(docker compose exec supportpal bash -c 'echo $SUPPORTPAL_MEILISEARCH_HOST' 2>/dev/null)"; then
        echo "ERROR: Failed to retrieve Meilisearch host URL from container" >&2
        echo "DEBUG: Ensure the supportpal container is running and SUPPORTPAL_MEILISEARCH_HOST is set" >&2
        exit 1
    fi

    echo "DEBUG: Using Meilisearch URL: $BASE_URL"

    # Check if Meilisearch is running with timeout
    echo "Checking Meilisearch health status..."
    local start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if (( elapsed >= health_check_timeout )); then
            echo "ERROR: Timeout waiting for Meilisearch to become healthy (${health_check_timeout}s)" >&2
            echo "DEBUG: Check Meilisearch container logs: docker compose logs supportpal" >&2
            exit 1
        fi

        if docker compose exec -T supportpal curl -fsS "$BASE_URL/health" -H "Authorization: Bearer $MASTER_KEY" >/dev/null 2>&1; then
            echo "✓ Meilisearch is ready and healthy"
            break
        fi

        echo "Waiting for Meilisearch to be ready... (${elapsed}/${health_check_timeout}s)"
        sleep 2
    done

    # Create dump with detailed error handling
    echo "Initiating Meilisearch dump creation..."
    if ! dump_response=$(docker compose exec -T supportpal curl -fsS -X POST "$BASE_URL/dumps" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $MASTER_KEY" 2>&1); then
        echo "ERROR: Failed to initiate dump creation" >&2
        echo "DEBUG: cURL response: $dump_response" >&2
        echo "DEBUG: Check Meilisearch logs: docker compose exec supportpal tail -n 50 /var/log/meilisearch.log" >&2
        exit 1
    fi

    echo "DEBUG: Dump API response: $dump_response"

    task_uid=$(echo "$dump_response" | grep -o "\"taskUid\":[0-9]*" | cut -d: -f2)

    if [ -z "$task_uid" ]; then
        echo "ERROR: Failed to extract task UID from dump creation response" >&2
        echo "DEBUG: Response was: $dump_response" >&2
        echo "DEBUG: Expected format: {\"taskUid\":123,...}" >&2
        exit 1
    fi

    echo "✓ Dump task created with UID: $task_uid"

    # Wait for dump to complete with enhanced status reporting
    echo "Monitoring dump progress..."
    start_time=$(date +%s)
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if (( elapsed >= dump_timeout )); then
            echo "ERROR: Timeout waiting for dump to complete (${dump_timeout}s)" >&2
            echo "DEBUG: Check task status manually: curl -H 'Authorization: Bearer \$MASTER_KEY' $BASE_URL/tasks/$task_uid" >&2
            exit 1
        fi

        if ! task_status=$(docker compose exec -T supportpal curl -fsS "$BASE_URL/tasks/$task_uid" \
            -H "Authorization: Bearer $MASTER_KEY" 2>&1); then
            echo "WARNING: Failed to check task status (attempt $((++retry_count))/$max_retries)" >&2
            echo "DEBUG: Response: $task_status" >&2

            if (( retry_count >= max_retries )); then
                echo "ERROR: Max retries exceeded checking dump status" >&2
                exit 1
            fi

            sleep 5
            continue
        fi

        # Reset retry count on successful API call
        retry_count=0

        # Extract status with better error handling
        if ! task_status=$(echo "$task_status" | grep -o "\"status\":\"[^\"]*\"" | cut -d: -f2 | tr -d "\""); then
            echo "WARNING: Failed to parse task status from response" >&2
            echo "DEBUG: Raw response: $task_status" >&2
            sleep 5
            continue
        fi

        case "$task_status" in
            succeeded)
                echo "✓ Pre-upgrade dump created successfully in ${elapsed}s"

                # Create a marker file to indicate pre-upgrade dump was created
                if ! docker compose exec -T -u meilisearch supportpal touch "/meilisearch/.pre_upgrade_dump_created" 2>/dev/null; then
                    echo "WARNING: Failed to create dump marker file (non-critical)" >&2
                fi
                return 0
                ;;
            failed)
                echo "ERROR: Pre-upgrade dump creation failed" >&2

                # Try to get error details
                local error_details
                if error_details=$(echo "$task_status" | grep -o "\"error\":\"[^\"]*\"" | cut -d: -f2 | tr -d "\""); then
                    echo "DEBUG: Error details: $error_details" >&2
                fi

                echo "DEBUG: Check Meilisearch logs for more details: docker compose exec supportpal tail -n 100 /var/log/meilisearch.log" >&2
                exit 1
                ;;
            enqueued|processing)
                echo "Dump in progress... (${elapsed}s elapsed, status: $task_status)"
                ;;
            *)
                echo "Dump status: $task_status (${elapsed}s elapsed)"
                ;;
        esac

        sleep 5
    done
}

# Usage: get_meilisearch_version <container_id>
get_meilisearch_version() {
    local CID="$1"
    local version_json="" start_ts=$(date +%s) retry_count=0 max_retries=10
    local timeout="${TIMEOUT:-180}"
    local retry_delay="${RETRY_DELAY:-3}"

    echo "DEBUG: Getting Meilisearch version from container: $CID" >&2
    echo "DEBUG: Timeout: ${timeout}s, Retry delay: ${retry_delay}s" >&2

    # Poll the version endpoint inside the container until it succeeds or times out.
    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_ts))

        # Check if container is still running
        if ! docker ps -q --no-trunc | grep -q "$CID"; then
            echo "ERROR: Container $CID exited before Meilisearch became ready (after ${elapsed}s)" >&2
            echo "DEBUG: Check container logs: docker logs $CID" >&2
            exit 1
        fi

        # Try to get version with detailed error handling
        echo "DEBUG: Attempting to get Meilisearch version (attempt $((retry_count + 1)), ${elapsed}s elapsed)" >&2

        if version_json="$(docker exec "$CID" bash -lc 'source <(sudo cat /etc/container_environment.sh) 2>/dev/null; curl -fsS -X GET "$SUPPORTPAL_MEILISEARCH_HOST/version" -H "Authorization: Bearer $MEILI_MASTER_KEY"' 2>&1)"; then
            echo "DEBUG: Successfully retrieved version response" >&2
            break
        else
            retry_count=$((retry_count + 1))
            echo "DEBUG: Failed to get version (attempt $retry_count/$max_retries)" >&2
            echo "DEBUG: Response: $version_json" >&2

            if (( retry_count >= max_retries )); then
                echo "ERROR: Max retries ($max_retries) exceeded while trying to get Meilisearch version" >&2
                echo "DEBUG: Container logs:" >&2
                docker logs --tail 20 "$CID" >&2 || true
                exit 1
            fi
        fi

        if (( elapsed >= timeout )); then
            echo "ERROR: Timed out waiting for Meilisearch to become ready (${timeout}s)" >&2
            echo "DEBUG: Container is running but Meilisearch API is not responding" >&2
            echo "DEBUG: Container logs:" >&2
            docker logs --tail 30 "$CID" >&2 || true
            exit 1
        fi

        echo "DEBUG: Waiting ${retry_delay}s before next attempt..." >&2
        sleep "$retry_delay"
    done

    echo "DEBUG: Raw version response: $version_json" >&2

    # Extract pkgVersion from the JSON with better error handling
    local pkgVersion
    if ! pkgVersion="$(echo "$version_json" | grep -oP '"pkgVersion"\s*:\s*"\K[^"]+')" || [ -z "${pkgVersion:-}" ]; then
        echo "ERROR: Failed to parse pkgVersion from Meilisearch version response" >&2
        echo "DEBUG: Expected JSON format: {\"pkgVersion\":\"1.x.x\",...}" >&2
        echo "DEBUG: Actual response: $version_json" >&2

        # Try alternative parsing methods
        local alt_version
        if alt_version="$(echo "$version_json" | sed -n 's/.*"pkgVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"; then
            if [ -n "$alt_version" ]; then
                echo "DEBUG: Alternative parsing succeeded: $alt_version" >&2
                pkgVersion="$alt_version"
            else
                exit 1
            fi
        else
            exit 1
        fi
    fi

    echo "DEBUG: Extracted Meilisearch version: $pkgVersion" >&2
    echo "$pkgVersion"
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

    local TIMEOUT="${TIMEOUT:-180}"        # seconds to wait for Meilisearch
    local RETRY_DELAY="${RETRY_DELAY:-3}"  # seconds between retries

    echo "DEBUG: Starting temporary container to get Meilisearch version..." >&2

    # Start the container detached; --rm ensures removal after it exits.
    local CID
    if ! CID="$(docker run -d --rm "$IMAGE" 2>&1)"; then
        echo "ERROR: Failed to start container with image: $IMAGE" >&2
        echo "DEBUG: Docker run output: $CID" >&2
        echo "DEBUG: Check if the image exists and is accessible" >&2
        exit 1
    fi

    echo "DEBUG: Started temporary container: $CID" >&2

    cleanup() {
        echo "DEBUG: Cleaning up temporary container: $CID" >&2
        # Stop the container; with --rm it will be removed automatically.
        docker stop -t 5 "$CID" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT INT TERM

    local version
    if ! version="$(get_meilisearch_version "$CID")"; then
        echo "ERROR: Failed to get Meilisearch version from temporary container" >&2
        cleanup
        exit 1
    fi

    echo "DEBUG: Successfully retrieved next Meilisearch version: $version" >&2
    echo "$version"
}

# Check if a version requires data dumping for upgrade
meili_requires_dump_upgrade() {
    local MEILISEARCH_DUMPLESS_VERSION="1.12.0"
    local from_version="$1"
    local to_version="$2"

    echo "DEBUG: Checking if Meilisearch dump is required for upgrade" >&2
    echo "DEBUG: Current version: $from_version" >&2
    echo "DEBUG: Target version: $to_version" >&2
    echo "DEBUG: Dumpless version threshold: $MEILISEARCH_DUMPLESS_VERSION" >&2

    # Validate input versions
    if [ -z "$from_version" ] || [ -z "$to_version" ]; then
        echo "ERROR: Both from_version and to_version must be provided" >&2
        echo "DEBUG: from_version='$from_version', to_version='$to_version'" >&2
        exit 1
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
        echo "DEBUG: Dump required - upgrading from pre-$MEILISEARCH_DUMPLESS_VERSION version" >&2
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
    if ! current_meili_version="$(get_meilisearch_version "$current_container_id")"; then
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
    if meili_requires_dump_upgrade "$current_meili_version" "$next_meili_version"; then
        echo "✓ Meilisearch dump is required for this upgrade"
        create_meilisearch_dump_pre_upgrade
    else
        echo "✓ No Meilisearch dump required for this upgrade"
    fi

    backup

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
upgrade
