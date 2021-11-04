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


upgrade() {
    docker-compose down -v
    curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-monolithic/docker-compose.yml -o docker-compose.yml
    docker-compose up
}

upgrade
