#!/bin/bash
set -eu -o pipefail

VOLUMES=("supportpal_db" "supportpal_config" "redis_data" )

# usage: check_command <bashrc__full_path>
check_command() {
  local _binary="$1" _full_path

  printf "checking for %s ... " "$_binary"

  # Checks if the binary is available.
  _full_path="$(command -v "$_binary")"
  _command_status="$?"
  if [ "$_command_status" -ne 0 ]; then
    printf "no\n"

    return 1
  else
    printf "found %s\n" "$_full_path"

    return 0
  fi
}

# usage: version_ge <installed_version> <minimum_version>
version_ge() {
  if ! [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; then
    printf "error: %s is less than minimum required version of %s\n" "$1" "$2"
    exit 1
  fi
}

check_docker() {
  if ! check_command docker; then
    printf "error: Install docker using the official installation instructions: https://docs.docker.com/engine/install/\n"
    exit 1
  fi

  local min="19.0.3" version

  set +e
  version="$(docker version -f "{{.Server.Version}}" 2>&1)"
  command_status="$?"
  set -e

  if [ $command_status -ne 0 ]; then
    echo "$version"

    if [[ "$version" == *"permission denied"* ]]; then
      echo
      echo "You may need to add your user to the docker group and then logout/login again for the change to take effect:"
      printf "\tsudo usermod -aG docker %s\n" "$USER"
      echo
      echo "Alternatively, consider installing rootless: https://docs.docker.com/engine/security/rootless/"
    fi
    exit 1
  fi

  printf "checking docker version %s >= %s ...\n" "$version" "$min"
  version_ge "$version" "$min"
}

create_volumes() {

  for volume in "${VOLUMES[@]}"
  do
    docker volume create --name="${volume}" > /dev/null
  done
}

setup_mysql() {
  echo "Setting up MySQL"

  database=supportpal
  root_password="$(docker run --rm public.ecr.aws/supportpal/helpdesk-configurator:latest openssl rand -base64 14)"
  username="$(docker run --rm public.ecr.aws/supportpal/helpdesk-configurator:latest openssl rand -base64 14)"
  user_password="$(docker run --rm public.ecr.aws/supportpal/helpdesk-configurator:latest openssl rand -base64 14)"

  docker run \
  --volume supportpal_db:/var/lib/mysql \
  -e MYSQL_DATABASE="${database}" \
  -e MYSQL_ROOT_PASSWORD="${root_password}" \
  -e MYSQL_USER="${username}" \
  -e MYSQL_PASSWORD="${user_password}" \
  -d \
  --rm sp-mysql > /dev/null;
}

check_volumes() {
    for volume in "${VOLUMES[@]}"
    do
      if docker volume ls | grep -q -E "${volume}"; then
          echo "Helpdesk is already installed."
          exit 1
      fi
    done
}

check_docker
check_volumes
create_volumes
setup_mysql

echo "Initializing helpdesk"
bash start.sh

echo "######################################################################"
echo
echo " Successfully Initialized the system."
echo
echo "######################################################################"
echo
echo " You can now open your web browser to the following address and run"
echo " the SupportPal installer, or you can enter your docker container using docker exec -it supportpal bash."
echo
echo " http://$(curl -s https://api.ipify.org)/"
echo
echo " Directories inside the docker container"
echo "   SupportPal: /var/www/supportpal"
echo "   Logs:       /var/log/"
echo
echo " MySQL"
echo "   Root Password: ${root_password}"
echo "   Database name: ${database}"
echo "   Username:      ${username}"
echo "   Password:      ${user_password}"
echo
echo "######################################################################"
