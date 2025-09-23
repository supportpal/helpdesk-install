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
    local MASTER_KEY BASE_URL
    MASTER_KEY="$(docker compose exec supportpal bash -c 'source <(sudo cat /etc/container_environment.sh) && echo $MEILI_MASTER_KEY')"
    BASE_URL="$(docker compose exec supportpal bash -c 'echo $SUPPORTPAL_MEILISEARCH_HOST')"

    echo "Creating Meilisearch data dump with current version before upgrade..."

    # Check if Meilisearch is running
    while true; do
        if docker compose exec -T supportpal curl -fsS "$BASE_URL/health" -H "Authorization: Bearer $MASTER_KEY" >/dev/null; then
            echo "Meilisearch is ready"
            break
        fi

        echo "Waiting for Meilisearch to be ready..."
        sleep 2
    done

    # Create dump
    dump_response=$(docker compose exec -T supportpal curl -fsS -X POST "$BASE_URL/dumps" -H "Content-Type: application/json" -H "Authorization: Bearer $MASTER_KEY")
    task_uid=$(echo "$dump_response" | grep -o "\"taskUid\":[0-9]*" | cut -d: -f2)

    if [ -z "$task_uid" ]; then
        echo "Failed to initiate dump creation:"
        echo "$dump_response"
        exit 1
    fi

    echo "Dump task created with UID: $task_uid"

    # Wait for dump to complete
    while true; do
        task_status=$(docker compose exec -T supportpal curl -fsS "$BASE_URL/tasks/$task_uid" -H "Authorization: Bearer $MASTER_KEY" | grep -o "\"status\":\"[^\"]*\"" | cut -d: -f2 | tr -d "\"")

        case "$task_status" in
            succeeded)
                echo "Pre-upgrade dump created successfully"

                # Create a marker file to indicate pre-upgrade dump was created
                docker compose exec -T -u meilisearch supportpal touch "/meilisearch/.pre_upgrade_dump_created"
                exit 0
                ;;
            failed)
                echo "Pre-upgrade dump creation failed"
                exit 1
                ;;
            *)
                echo "Dump in progress..."
                sleep 5
                ;;
        esac
    done
}

# Usage: get_meilisearch_version <container_id>
get_meilisearch_version() {
    local CID="$1"
    local version_json="" start_ts=$(date +%s)

    # Poll the version endpoint inside the container until it succeeds or times out.
    while true; do
        if ! docker ps -q --no-trunc | grep -q "$CID"; then
            echo "Container exited before Meilisearch became ready." >&2
            exit 1
        fi

        if version_json="$(docker exec "$CID" bash -lc 'source <(sudo cat /etc/container_environment.sh); curl -fsS -X GET "$SUPPORTPAL_MEILISEARCH_HOST/version" -H "Authorization: Bearer $MEILI_MASTER_KEY"')"; then
            break
        fi

        now=$(date +%s)
        if (( now - start_ts >= TIMEOUT )); then
            echo "Timed out waiting for Meilisearch to become ready." >&2
            exit 1
        fi

        sleep "$RETRY_DELAY"
    done

    # Extract pkgVersion from the JSON
    pkgVersion="$(echo "$version_json" | grep -oP '"pkgVersion"\s*:\s*"\K[^"]+')"
    if [ -z "${pkgVersion:-}" ]; then
        echo "Failed to parse pkgVersion from response: $version_json" >&2
        exit 1
    fi

    echo "$pkgVersion"
}

get_next_meilisearch_version() {
    IMAGE=$(curl -fsSL "${COMPOSE_FILE_DOWNLOAD_URL}" \
        | grep -m1 -E '^[[:space:]]*image:' \
        | sed -E "s/^[[:space:]]*image:[[:space:]]*//; s/^['\"]//; s/['\"]$//")

    TIMEOUT="${TIMEOUT:-180}"        # seconds to wait for Meilisearch
    RETRY_DELAY="${RETRY_DELAY:-3}"  # seconds between retries

    # Start the container detached; --rm ensures removal after it exits.
    CID="$(docker run -d --rm "$IMAGE")"

    cleanup() {
      # Stop the container; with --rm it will be removed automatically.
      docker stop -t 5 "$CID" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT INT TERM

    echo "$(get_meilisearch_version "$CID")"
}

# Check if a version requires data dumping for upgrade
meili_requires_dump_upgrade() {
    local MEILISEARCH_DUMPLESS_VERSION="1.12.0"
    local from_version="$1"
    local to_version="$2"

    # If upgrading from < 1.12.0 to any version, dump is required
    if [ "$(printf '%s\n' "$from_version" "$MEILISEARCH_DUMPLESS_VERSION" | sort -V | head -n1)" = "$from_version" ] && [ "$from_version" != "$MEILISEARCH_DUMPLESS_VERSION" ]; then
        return 0  # true - dump required
    fi

    return 1  # false - no dump required
}

upgrade() {
    current_meili_version="$(get_meilisearch_version $(docker compose ps -q supportpal))"
    if requires_dump_upgrade "$current_meili_version" "$(get_next_meilisearch_version)"; then
        create_meilisearch_dump_pre_upgrade
    fi

    backup
    docker compose down -v
    update_volumes
    update_env
    update_compose_files
    if [ "${only_files}" = true ]; then
        exit 0
    fi

    COMPOSE_PARALLEL_LIMIT=1 docker compose up -d
    docker compose exec supportpal bash -c "bash /init/upgrade-helpdesk.sh"
    echo
    echo "Upgrade complete!"
}

check_docker_compose
upgrade
