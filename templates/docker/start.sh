#!/bin/bash
set -eu -o pipefail

VERSION="3.6.0"
WEB_PORT="80"
WS_PORT="6001"

CORE_VOLUMES=("supportpal_db" "supportpal_config" "supportpal_redis" "supportpal_storage")
CONTAINER_NAME="supportpal"

check_volumes() {
    for volume in "${CORE_VOLUMES[@]}"
    do
        if ! docker volume ls | grep -q "${volume}"; then
            echo "Helpdesk is not initialized."
            exit 1
        fi
    done
}

check_if_running() {
  if docker ps | grep -q "${CONTAINER_NAME}"; then
      echo "Helpdesk is already running."
      exit 1
  fi
}

check_volumes
check_if_running

PHP_VERSION="7.4"
CLI_PATH="/etc/php/${PHP_VERSION}/cli/conf.d/999-custom-config.ini"
FPM_PATH="/etc/php/${PHP_VERSION}/fpm/conf.d/999-custom-config.ini"

docker run \
--volume supportpal_db:/var/lib/mysql \
--volume supportpal_config:/var/www/supportpal/config/production \
--volume supportpal_redis:/redis-data \
--volume supportpal_storage:/var/www/supportpal/storage \
--volume "${PWD}/customization/:/customization" \
--volume "${PWD}/php/custom.ini:/${CLI_PATH}" \
--volume "${PWD}/php/custom.ini:/${FPM_PATH}" \
-p "127.0.0.1:${WEB_PORT}:80" \
-p "127.0.0.1:${WS_PORT}:6001" \
--name supportpal \
-d \
--rm -t -i "supportpal:${VERSION}" /sbin/my_init > /dev/null
