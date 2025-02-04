#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.
    -r,--ref=5.x               Git ref (commit sha, ref name, tag) to run the script on.
    --skip-backup              Skip taking a backup before upgrading.
"

# options
ref=5.x
skip_backup=false

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
    *)
        echo "Unknown parameter passed: $1"
        exit 1
        ;;
    esac
    shift
done

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

    time_now=$(date +"%d-%m-%Y-%H:%M:%S")
    cp -n docker-compose.yml "docker-compose.backup-${time_now}.yml"

    bash <(curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/5.x/templates/docker-monolithic/backup.sh)
}

update_compose_files() {
    curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/"${ref}"/templates/docker-monolithic/docker-compose.yml -o docker-compose.yml
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

upgrade() {
    backup
    docker compose down -v
    update_volumes
    update_env
    update_compose_files
    COMPOSE_PARALLEL_LIMIT=1 docker compose up -d
    docker compose exec supportpal bash -c "bash /init/upgrade-helpdesk.sh"
    echo
    echo "Upgrade complete!"
}

check_docker_compose
upgrade
