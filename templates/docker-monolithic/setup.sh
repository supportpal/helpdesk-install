#!/bin/bash
set -eu -o pipefail

usage="Options:
    -h,--help                  Display this help and exit.

    -n                         Run the command non interactively.

    -r,--ref=                  Git ref (commit sha, ref name, tag) to run the script on.

    -H,--host=                 Domain name to use with SupportPal.

    -e,--email=                System administrator email address to receive cron notifications.
"

# Options
interactive=1
host=
email=
ref=5.x

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  -n) interactive=0 ;;
  -H|--host) host="$2" ; shift ;;
  -e|--email) email="$2" ; shift ;;
  -r|--ref) ref="$2" ; shift ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
  # shellcheck disable=SC2317
  shift
done

os_type=
identify_os() {
  # Check for RHEL/CentOS, Fedora, etc.
  if command -v rpm >/dev/null && [[ -e /etc/redhat-release ]]; then
    os_type=rhel
  elif [[ -e /etc/os-release ]]; then
    . /etc/os-release
    # Is it Debian?
    case $ID in
    debian)
      os_type=debian ;;
    ubuntu)
      os_type=ubuntu ;;
    esac
  elif [[ "$(uname -s)" == Darwin ]]; then
    os_type=macos
  elif [[ "$(uname -s)" == MINGW* ]]; then
    os_type=windows
  fi

  if ! [[ $os_type ]]; then
    printf "error: unsupported operating system.\n"
    printf "\tFor a list of supported operating systems see https://docs.supportpal.com/current/System+Requirements#OperatingSystems\n"
    echo
    exit 1
  fi
}

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

check_winpty() {
  if ! check_command winpty; then
    printf "error: winpty is missing. Install Git Bash using the default options.\n"
    exit 1
  fi
}

configure_windows() {
  if [[ "$os_type" != "windows" ]]; then
    return
  fi

  check_winpty

  # winpty is required to run docker interactively (create a tty).
  path="${HOME}/.winpty/supportpal.sh"
  if [[ ! -e "${path}" ]]; then
    printf "registering winpty aliases ...\n"

    mkdir -p "$(dirname "${path}")"
    echo "alias docker='winpty docker'" >> "${path}"

    echo "[ -f ${path} ] && . ${path}" >> ~/.bashrc
    echo "[ -f ${path} ] && . ${path}" >> ~/.bash_profile
  fi

  # shellcheck disable=SC1090
  . "${path}"
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

  printf "checking docker version %s >= %s ... " "$version" "$min"
  version_ge "$version" "$min"
  printf "✔\n"
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

escape_re() {
  IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g' <<<"$1")
  printf %s "${REPLY%$'\n'}"
}

create_volume() {
  printf "creating docker volume of name %s ... " "$1"
  # shellcheck disable=SC2034
  output="$(docker volume create "$1")"
  printf "✔\n"
}

configure() {
  # download docker-compose.yml example
  printf "generating docker-compose.yml ... "
  if [[ -f "docker-compose.yml" ]]; then
    echo
    echo "error: $(pwd)/docker-compose.yml already exists. Delete the file and try again."
    exit 1
  fi
  curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/"${ref}"/templates/docker-monolithic/docker-compose.yml -o docker-compose.yml
  curl -fLsS https://raw.githubusercontent.com/supportpal/helpdesk-install/"${ref}"/templates/docker-monolithic/docker-compose.override.yml -o docker-compose.override.yml

  echo "" > .env

  if [ "$interactive" -eq 1 ]; then
    echo
    echo "Enter system administrator email address."
    echo "This will notify you if there's a problem with the cron and allow you to take corrective action."
    read -r email

    echo
    echo "Enter system domain name. Leave blank to configure later..."
    read -r host
  fi

  # If unset or empty, guess the hostname.
  if [[ -z "${host// }" ]]; then
    host="$(hostname)"
  fi

  echo "DOMAIN_NAME=$(escape_re "${host// }")" >> .env
  printf "wrote 'DOMAIN_NAME=%s' to .env ✔\n" "${host// }"

  if [[ -n "${email// }" ]]; then
    echo "MAILTO=$(escape_re "${email// }")" >> .env
    printf "wrote 'MAILTO=%s' to .env ✔\n" "${email// }"
  fi

  # create volumes
  bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/"${ref}"/templates/docker-monolithic/create_volumes.sh)
}

check_memory() {
  if ! [ -f /proc/meminfo ]; then
    return
  fi

  # Get total memory (RAM + Swap) in kilobytes
  total_memory=$(awk '/MemTotal/ {mem=$2} /SwapTotal/ {swap=$2} END {print mem+swap}' /proc/meminfo)

  # 4GB (approx)
  required_memory=$((4*1000*1000))

  if (( total_memory < required_memory )); then
    echo "##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####"
    echo "                         !! WARNING !!                           "
    echo "##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####"
    echo ""
    echo "The system has less than 4GB of total memory (RAM + Swap),"
    echo "detected ${total_memory}KB. The system may crash if launched with"
    echo "insufficient memory."
    echo
    echo "Greater than ${required_memory}KB is recommended."
    echo
    echo "Press CTRL+C to exit and add more RAM/Swap. Continuing in 15s..."
    echo
    echo "##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####"
    echo
    sleep 15
  fi
}

cat << "EOF"
 ____                               _   ____       _
/ ___| _   _ _ __  _ __   ___  _ __| |_|  _ \ __ _| |
\___ \| | | | '_ \| '_ \ / _ \| '__| __| |_) / _` | |
 ___) | |_| | |_) | |_) | (_) | |  | |_|  __/ (_| | |
|____/ \__,_| .__/| .__/ \___/|_|   \__|_|   \__,_|_|
            |_|   |_|
EOF

echo
identify_os
check_memory
configure_windows
check_docker
check_docker_compose
configure

echo
echo "To complete the installation update the auto-generated $(pwd)/.env file."
echo "Refer back to https://docs.supportpal.com/current/Deploy+on+Docker for suggested changes."
echo
