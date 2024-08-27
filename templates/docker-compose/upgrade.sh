#!/bin/bash

set -eu -o pipefail

${MAKE} create_volumes
${DOCKER_COMPOSE_BIN} "${COMPOSE_FILES}" up -d supportpal
${DOCKER_BIN} exec -it "${WEB_SERVICE_NAME}" bash /scripts/upgrade-helpdesk.sh
${MAKE} start
