#!/bin/bash

set -eu -o pipefail

. .env
TIMESTAMP=$(date +%s-%F)

mkdir -p "backup/${TIMESTAMP}/mysql/" && docker cp "${DATABASE_SERVICE_NAME}:/var/lib/mysql" "backup/${TIMESTAMP}/mysql/"
mkdir -p "backup/${TIMESTAMP}/cache/" && docker cp "${CACHE_SERVICE_NAME}:/data" "backup/${TIMESTAMP}/cache/"
mkdir -p "backup/${TIMESTAMP}/mailer/" && docker cp "${MAILER_SERVICE_NAME}:/var/spool/exim4" "backup/${TIMESTAMP}/mailer/"
mkdir -p "backup/${TIMESTAMP}/config/" && docker cp "${WEB_SERVICE_NAME}:/supportpal/config/production" "backup/${TIMESTAMP}/config/"
mkdir -p "backup/${TIMESTAMP}/storage/" && docker cp "${WEB_SERVICE_NAME}:/supportpal/storage" "backup/${TIMESTAMP}/storage/"

echo "Backups created successfully at ${PWD}/backup/${TIMESTAMP}"
