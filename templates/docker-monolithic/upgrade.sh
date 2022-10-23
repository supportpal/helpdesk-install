#!/bin/bash
set -eu -o pipefail

usage="Usage (Linux / MacOS): bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-monolithic/upgrade.sh)

Usage (Windows / Git Bash): winpty bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-monolithic/upgrade.sh)

Options:
    -h,--help                  Display this help and exit.
"

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
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

backup_config() {
    time_now=$(date +"%d-%m-%Y-%H:%M:%S")
    cp -n docker-compose.yml "docker-compose.backup-${time_now}.yml"
}

update_compose_files() {
    curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-monolithic/docker-compose.yml -o docker-compose.yml
}

update_volumes() {
    bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-monolithic/create_volumes.sh)
}

migrate_hostname() {
      grep  "hostname" docker-compose.override.yml | xargs | sed "s/hostname: /DOMAIN_NAME=/" >> .env
      if [[ "$(uname -s)" == Darwin ]]; then
          sed -i "" -e "s/hostname:.*/hostname: ''/" docker-compose.override.yml
      else
          sed -i -e "s/hostname:.*/hostname: ''/" docker-compose.override.yml
      fi
}

update_env() {
  if ! grep -qs 'DOMAIN_NAME' .env; then
    migrate_hostname
  fi
}

upgrade() {
    docker compose down -v
    backup_config
    update_volumes
    update_env
    update_compose_files
    docker compose up -d
    echo
    echo "Upgrade complete!"
}

check_docker_compose
upgrade
