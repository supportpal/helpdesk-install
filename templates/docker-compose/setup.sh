#!/bin/bash
set -eu -o pipefail

usage="Usage (Linux): curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-compose/setup.sh | bash

Usage (Windows / Git Bash): winpty bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-compose/setup.sh)

Options:
    -h,--help                  Display this help and exit.

    -n                         Run the command non interactively.

    -H,--host=                 Domain name to use with SupportPal.

    -e,--email=                System administrator email address to receive cron notifications.
"

# Options
interactive=1
host=
email=

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -h|--help) echo "$usage" ; exit 0 ;;
  -n) interactive=0 ;;
  -H|--host) host="$2" ; shift ;;
  -e|--email) email="$2" ; shift ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
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

# usage: check_command <path>
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
  aliases="alias docker='winpty docker'"
  if [[ ! -e ~/.bashrc ]] || [[ $(grep -L "${aliases}" ~/.bashrc) ]]; then
    printf "registering winpty aliases to ... %s %s\n" ~/.bashrc ~/.bash_profile
    echo "${aliases}" >> ~/.bashrc
    echo "[ -f ~/.bashrc ] && . ~/.bashrc" >> ~/.bash_profile
  fi
  
  source ~/.bash_profile
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

check_docker_compose() {
  if ! check_command docker-compose; then
    printf "error: Install docker-compose using the official installation instructions: https://docs.docker.com/compose/install/\n"
    exit 1
  fi

  local min="1.24.0" version

  version="$(docker-compose version --short)"
  printf "checking docker-compose version %s >= %s ...\n" "$version" "$min"
  version_ge "$version" "$min"
}

check_git() {
  if ! check_command git; then
    printf "error: Install git using the official installation instructions: https://git-scm.com/downloads\n"
    exit 1
  fi
}

check_make() {
  if ! check_command make; then
    printf "error: Install make for your distro.\n"

    if [[ $os_type == 'rhel' ]]; then
      printf "       sudo yum install make -y\n"
    elif [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
      printf "       sudo apt install make -y\n"
    elif [[ $os_type == 'windows' ]]; then
      printf "       see https://chocolatey.org/packages/make\n"
    fi

    exit 1
  fi
}

escape_re() {
  IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g' <<<"$1")
  printf %s "${REPLY%$'\n'}"
}

configure() {
  git clone https://github.com/supportpal/helpdesk-install.git
  cd helpdesk-install/templates/docker-compose

  cp .env.dist .env
  cp Makefile.dist Makefile

  if [ "$interactive" -eq 1 ]; then
    echo
    echo "Enter system administrator email address."
    echo "This will notify you if there's a problem with the cron and allow you to take corrective action."
    read -r email

    echo
    echo "Enter system domain name. Leave blank to configure later..."
    read -r host
  fi

  if [[ -n "${email// }" ]]; then
    sed -i -E "s/^(MAILTO=).*/\1$(escape_re "${email// }")/" .env
    printf "wrote 'MAILTO=%s' to .env\n" "${email// }"
  fi

  if [[ -n "${host// }" ]]; then
    sed -i -E "s/^(HOST=).*/\1$(escape_re "${host// }")/" .env
    printf "wrote 'HOST=%s' to .env\n" "${host// }"

    sed -i -E "s/^(DOMAIN_NAME=).*/\1$(escape_re "${host// }")/" .env
    printf "wrote 'DOMAIN_NAME=%s' to .env\n" "${host// }"
  fi
}

identify_os
configure_windows
check_docker
check_docker_compose
check_git
check_make
echo
configure
make install
