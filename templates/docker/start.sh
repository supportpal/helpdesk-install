#!/bin/bash
set -eu -o pipefail

VOLUMES=("supportpal_db" "supportpal_config" "supportpal_redis" )
CONTAINER_NAME="supportpal"

check_volumes() {
    for volume in "${VOLUMES[@]}"
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

docker run \
--volume supportpal_db:/var/lib/mysql \
--volume supportpal_config:/var/www/supportpal/config/production \
--volume supportpal_redis:/redis-data \
-p 127.0.0.1:80:80 \
-p 127.0.0.1:6001:6001 \
--name supportpal \
-d \
--rm -t -i sp-mono /sbin/my_init > /dev/null
