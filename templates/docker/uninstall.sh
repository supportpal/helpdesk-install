#!/bin/bash

printf "\033[0;33m|---------------------|\033[0m\n"
printf "\033[0;33m|       WARNING       |\033[0m\n"
printf "\033[0;33m|---------------------|\033[0m\n"
echo
printf "\033[0;33mThis action will irreversibly uninstall your help desk. This includes, but not limited to, permanent removal of the database and all user files.\033[0m\n"
printf "\033[0;33mDo NOT continue without a recent full system backup. You can take a backup of your system by executing: make backup\033[0m\n"
echo
printf "\033[0;33mPress CTRL + C to cancel this operation. Waiting 15 seconds...\033[0m\n"
sleep 15


echo "Cleaning up containers"
docker rm -f supportpal 2> /dev/null

echo "Cleaning up volumes"
VOLUMES=("supportpal_db" "supportpal_config" "redis_data" )
for volume in "${VOLUMES[@]}"
do
  docker volume remove "${volume}" 2> /dev/null
done

echo "Uninstall complete"
