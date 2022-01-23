#!/bin/bash
set -eu -o pipefail

version="0.1.0"

supported="The following Linux OSs are supported, on x86_64 only:
    * RHEL/CentOS 8 (rhel)
    * Ubuntu 18.04 LTS (bionic), & 20.04 LTS (focal)
    * Debian 9 (stretch) & 10 (buster)"

usage="Usage: curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/linux/setup.sh | sudo bash -s -- [options]

$supported

Options:
    --help                  Display this help and exit.

    --version               Output the script version and exit.

    --overwrite             Permanently delete existing configurations, databases, files.

    --docker                Use for testing purposes only; replaces systemd to allow testing in docker containers.
"

# whether to overwrite files, databases, etc.
overwrite=0
# whether running in docker container
is_docker=
# os_type = ubuntu, debian, rhel, sles
os_type=
# os_version as demanded by the OS (codename, major release, etc.)
os_version=
# php version to install
php_version='7.4'
# mysql authentication
root_password=
database='supportpal'
username='supportpal'
user_password=
# php-fpm
install_path='/var/www/supportpal'
log_path='/var/log/supportpal'
socket_path='/var/run/supportpal.sock'

while [[ "$#" -gt 0 ]]; do
  case $1 in
  --version)
    echo "$version"
    exit 0
    ;;
  --help)
    echo "$usage"
    exit 0
    ;;
  --docker) is_docker=1 ;;
  --overwrite) overwrite=1 ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
  shift
done

msg() {
  type=$1 #${1^^}
  shift
  printf "[$type] %s\n" "$@" >&2
}

error() {
  msg error "$@"
  exit 1
}

identify_os() {
  arch=$(uname -m)
  # Check for RHEL/CentOS, Fedora, etc.
  if command -v rpm >/dev/null && [[ -e /etc/redhat-release ]]; then
    os_type=rhel
    el_version=$(rpm -qa '(oraclelinux|sl|redhat|centos|fedora)*release(|-server)' --queryformat '%{VERSION}')
    case $el_version in
    8*) os_version=8 ;;
    *) error "Detected RHEL or compatible but version ($el_version) is not supported." "$supported" ;;
    esac
  elif [[ -e /etc/os-release ]]; then
    . /etc/os-release
    # Is it Debian?
    case $ID in
    debian)
      os_type=debian
      debian_version=$(</etc/debian_version)
      case $debian_version in
      9*) os_version=stretch ;;
      10*) os_version=buster ;;
      *) error "Detected Debian but version ($debian_version) is not supported." "$supported" ;;
      esac
      ;;
    ubuntu)
      os_type=ubuntu
      . /etc/lsb-release
      os_version=$DISTRIB_CODENAME
      case $os_version in
      precise) error 'Ubuntu version 12.04 LTS has reached End of Life and is no longer supported.' ;;
      trusty) error 'Ubuntu version 14.04 LTS has reached End of Life and is no longer supported.' ;;
      xenial) ;;
      bionic) ;;
      focal) ;;
      *) error "Detected Ubuntu but version ($os_version) is not supported." "Only Ubuntu LTS releases are supported." ;;
      esac
      if [[ $arch == aarch64 ]]; then
        case $os_version in
        xenial) ;;
        bionic) ;;
        focal) ;;
        *) error "Only Ubuntu 16/xenial, 18/bionic, and 20/focal are supported for ARM64. Detected version: '$os_version'" ;;
        esac
      fi
      ;;
    esac
  fi
  if ! [[ $os_type ]] || ! [[ $os_version ]]; then
    error "Unsupported operating system." "$supported"
  fi
}

check_root() {
  if [ "$(id -u)" != "0" ]; then
    error "This script must be ran as root."
  fi
}

detect_supportpal() {
  if [ "$overwrite" == "0" ] && [ -d "$install_path" ]; then
    error "Unable to install SupportPal. ${install_path} already exists."
  fi
}

backup() {
  for path in "$@"; do
    path=$(realpath -s "$path")
    if [[ -e "$path" ]]; then
      new_name="$path.old_"
      i=1
      while [[ -e "${new_name}${i}" || -L "${new_name}${i}" ]]; do
        ((i++))
      done

      new_name="${new_name}${i}"

      msg "info" "Backing up $path to $new_name ..."
      cp -R "$path" "$new_name"
    fi

    rm -rf "$path"
  done
}

install() {
  if [[ $os_type == 'rhel' ]]; then
    install_rpm "$@"
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    apt-get install -y "$@"
  fi
}

update() {
  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    apt-get update -y
  fi
}

install_rpm() {
  dnf install -y "$@"
}

remove_rpm() {
  dnf remove -y "$@"
}

systemd() {
  msg "info" "issuing $1 of service: $2..."

  # Allow us to test this script in docker, not intended for production use.
  # We replace systemctl every time because sometimes the package manager updates systemd between calls.
  if ((is_docker == 1)); then
    if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
      install debconf-utils
    elif [[ $os_type = 'rhel' ]]; then
      install which
    fi

    install python3
    SYSTEMCTL=$(which systemctl || echo '/bin/systemctl')
    curl -o "$SYSTEMCTL" https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py
    chmod +x "$SYSTEMCTL"
    systemctl "$1" "$2"
  elif [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    service "$2" "$1"
  elif [[ $os_type = 'rhel' ]]; then
    systemctl "$1" "$2"
  fi

  msg "info" "issued $1 of service: $2"
}

# pwgen 2.08 is unavailable on debian 9 (stretch).
install_pwgen()
{
  # install dependencies
  install curl gcc make

  curl -L -O https://kumisystems.dl.sourceforge.net/project/pwgen/pwgen/2.08/pwgen-2.08.tar.gz
  tar -xzf pwgen-2.08.tar.gz
  cd pwgen-2.08
  ./configure
  make && make install
  cd ..
  rm -rf pwgen-2.08.tar.gz pwgen-2.08
}

setup() {
  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    export DEBIAN_FRONTEND=noninteractive
  fi

  update
  install curl
  install_pwgen
}

#
# PHP
#

configure_php_fpm() {
  # /var/run and /run are tmpfs so are emptied on reboot
  # /etc/systemd/system/multi-user.target.wants/php7.4-fpm.service tries to create files in /run/php
  # unable to bind listening socket for address '/run/php/php7.4-fpm.sock': No such file or directory
  mkdir -p /run/php "$(dirname "${socket_path}")"

  echo "[supportpal]

listen = ${socket_path}
listen.allowed_clients = 127.0.0.1
listen.owner = $1
listen.group = $1
listen.mode = 0666

user = $1
group = $1

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.process_idle_timeout = 10s
pm.max_requests = 500

slowlog = ${log_path}/php-fpm-slow.log

php_admin_value[error_log] = ${log_path}/php-fpm-error.log
php_admin_value[log_errors] = on
" > "$2"
}

install_php_rhel() {
  install_rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
  install_rpm https://rpms.remirepo.net/enterprise/remi-release-8.rpm
  dnf -y module reset php && dnf -y module enable "php:remi-${php_version}"
  dnf -y install php php-fpm php-bcmath php-gd php-mbstring php-mysql php-xml php-imap php-ldap php-zip

  if [[ -x "$(command -v getenforce)" ]] && [[ "$(getenforce)" != "disabled" ]]; then
    semanage fcontext -a -t httpd_var_run_t "${socket_path}"
  fi

  configure_php_fpm apache /etc/php-fpm.d/supportpal.conf

  systemd restart php-fpm
}

install_php_deb() {
  apt-get -y install apt-transport-https lsb-release ca-certificates gnupg2

  GPG_PATH="/etc/apt/trusted.gpg.d/php.gpg"
  backup "$GPG_PATH"
  curl -o "$GPG_PATH" https://packages.sury.org/php/apt.gpg

  APT_SOURCES_PATH="/etc/apt/sources.list.d/php.list"
  backup "$APT_SOURCES_PATH"
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" >"$APT_SOURCES_PATH"

  apt-get update
}

install_php_ubuntu() {
  apt-get install -y software-properties-common gnupg2
  LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y && apt-get update -y
}

install_php() {
  msg "info" "Installing PHP..."

  if [[ $os_type == 'rhel' ]]; then
    install_php_rhel
  elif [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    if [[ $os_type == 'debian' ]]; then
      install_php_deb
    elif [[ $os_type == 'ubuntu' ]]; then
      install_php_ubuntu
    fi

    apt-get install -y "php${php_version}" "php${php_version}-fpm" "php${php_version}-dom" \
    "php${php_version}-gd" "php${php_version}-mbstring" "php${php_version}-mysql" "php${php_version}-xml" \
    "php${php_version}-curl" "php${php_version}-bcmath" "php${php_version}-ldap" "php${php_version}-imap" \
    "php${php_version}-zip"

    configure_php_fpm www-data "/etc/php/${php_version}/fpm/pool.d/supportpal.conf"

    systemd start "php${php_version}-fpm"
  fi

  install_ioncube
}

install_ioncube() {
  # Get PHP extension directory.
  PHP_EXT_DIR=$(php -i | grep ^extension_dir | awk -F '=> ' '{print $3}')
  [[ "${PHP_EXT_DIR}" != */ ]] && PHP_EXT_DIR="${PHP_EXT_DIR}/"

  # Install Ioncube Loaders
  IONCUBE_EXT="zend_extension = "${PHP_EXT_DIR}ioncube_loader_lin_${php_version}.so""
  curl --fail -o ioncube_loaders_lin_x86-64.tar.gz https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
  tar xfz ioncube_loaders_lin_x86-64.tar.gz
  cp "ioncube/ioncube_loader_lin_${php_version}.so" "${PHP_EXT_DIR}"

  if [[ $os_type == 'rhel' ]]; then
    INI_PATH="/etc/php.d/00-ioncube.ini"
    backup "$INI_PATH"
    echo "$IONCUBE_EXT" >"$INI_PATH"

    systemd restart php-fpm
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    INI_PATH="/etc/php/${php_version}/fpm/conf.d/00-ioncube.ini"
    backup "$INI_PATH"
    echo "$IONCUBE_EXT" >"$INI_PATH"

    INI_PATH="/etc/php/${php_version}/cli/conf.d/00-ioncube.ini"
    backup "$INI_PATH"
    echo "$IONCUBE_EXT" >"$INI_PATH"

    systemd restart "php${php_version}-fpm"
  fi

  rm -rf ioncube*
}

#
# Web Server
#

write_vhost() {
  mkdir -p "${log_path}"

  echo "<VirtualHost _default_:80>
    DocumentRoot \"${install_path}\"
    DirectoryIndex index.php

    <Directory \"${install_path}\">
        Require all granted
        AllowOverride All
    </Directory>

    ErrorLog ${log_path}/error.log
    CustomLog ${log_path}/access.log combined

    <Proxy \"unix:${socket_path}|fcgi://php-fpm\">
        ProxySet disablereuse=off
    </Proxy>

    <FilesMatch \.php$>
        SetHandler proxy:fcgi://php-fpm
    </FilesMatch>
</VirtualHost>
" >"$1"
}

install_apache_rhel() {
  install httpd firewalld
  systemd restart httpd && systemd enable httpd
  systemd restart firewalld && systemd enable firewalld
  firewall-cmd --add-service=http --add-service=https --permanent && firewall-cmd --reload

  backup /etc/httpd/conf.d/welcome.conf

  write_vhost /etc/httpd/conf.d/supportpal.conf

  systemd restart httpd
}

install_apache_deb() {
  install apache2
  a2enmod rewrite proxy_fcgi

  write_vhost /etc/apache2/sites-available/supportpal.conf
  ln -sf /etc/apache2/sites-available/supportpal.conf /etc/apache2/sites-enabled/supportpal.conf

  default="/etc/apache2/sites-enabled/000-default.conf"
  if [ -L "$default" ]; then
    unlink "$default"
  fi

  systemd restart apache2
}

install_apache() {
  msg "info" "Configuring Apache2..."

  if [[ $os_type == 'rhel' ]]; then
    install_apache_rhel
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    install_apache_deb
  fi

  install_php
}

#
# Database
#

generate_password() {
  local passwd

  passwd=""

  # it's possible for pwgen to generate strings that are single case
  # strong passwords must be:
  #     Length >= 8, numeric, mixed case, special characters and dictionary file
  while [[ $passwd = "${passwd,,}" ]] || [[ $passwd = "${passwd^^}" ]]; do
    # sudo only provides access to /sbin:/bin:/usr/sbin:/usr/bin
    # commands in /usr/local/bin cannot be found (https://unix.stackexchange.com/a/8652).
    passwd=$(/usr/local/bin/pwgen -1 -s -y -n -c -v -r \`\'\"\$\|\\ 15)
  done

  echo "${passwd}"
}

install_mysql() {
  msg "info" "Installing MySQL..."

  install openssl
  root_password="$(generate_password)"
  tmp_root=root_password
  user_password="$(generate_password)"

  if [[ $os_type == 'rhel' ]]; then
    install_rpm https://dev.mysql.com/get/mysql80-community-release-el8-1.noarch.rpm
    dnf -y module disable mysql
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    install wget debconf-utils lsb-release gnupg2
    debconf-set-selections <<< "mysql-apt-config mysql-apt-config/select-product select Ok"
    debconf-set-selections <<< "mysql-server mysql-server/root_password password ${root_password}"
    debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${root_password}"

    wget -O mysql-apt-config.deb https://dev.mysql.com/get/mysql-apt-config_0.8.22-1_all.deb
    dpkg -i mysql-apt-config.deb && apt-get update
    rm mysql-apt-config.deb
  fi

  if [[ $os_type == 'rhel' ]]; then
    if [ "$overwrite" == "1" ]; then
      remove_rpm mysql-community-server
      backup /var/lib/mysql/ /var/log/mysqld.log
    fi

    install mysql-community-server
    systemd restart mysqld

    tmp_root=$(grep "A temporary password is generated" /var/log/mysqld.log | awk '{print $NF}')

    # Allow SupportPal (httpd) to connect to the DB via 127.0.0.1
    if [[ -x "$(command -v getenforce)" ]] && [[ "$(getenforce)" != "disabled" ]]; then
      setsebool -P httpd_can_network_connect 1
    fi
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    if [ "$overwrite" == "1" ]; then
      apt-get remove -y --purge mysql-server && apt-get -y autoremove
      backup /var/lib/mysql/
    fi

    install mysql-server
    systemd restart mysql
  fi

  while ! mysqladmin ping --silent; do
    echo "mysql-server is unavailable. retrying in 1s..."
    sleep 1
  done

  mysql --connect-expired-password --user='root' --password="${tmp_root}" -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${root_password}'; FLUSH PRIVILEGES;"
  if [[ $os_type == 'rhel' ]]; then
    mysql --user="root" --password="${root_password}" -e "UNINSTALL COMPONENT 'file://component_validate_password';"
  fi
  mysql --user="root" --password="${root_password}" -e "CREATE DATABASE \`${database}\`;"
  mysql --user="root" --password="${root_password}" -e "CREATE USER '${username}'@'localhost' IDENTIFIED BY '$user_password';"
  mysql --user="root" --password="${root_password}" -e "GRANT ALL PRIVILEGES ON \`${database}\`.* TO '${username}'@'localhost';"
  mysql --user="root" --password="${root_password}" -e "FLUSH PRIVILEGES;"
}

install_supportpal() {
  install jq unzip
  URLS=$( curl -sL https://licensing.supportpal.com/api/version/available.json | jq -r '.version[].artifacts[].download_url' | tr '\n' ' ')
  DOWNLOAD_URL=$(echo "$URLS" | grep ".zip" | cut -d' ' -f1)
  curl "${DOWNLOAD_URL}" -o /tmp/supportpal.zip
  unzip -qo /tmp/supportpal.zip -d "${install_path}"
  rm /tmp/supportpal.zip

  if [[ $os_type == 'rhel' ]]; then
    chown -R apache:apache "${install_path}"

    if [[ -x "$(command -v getenforce)" ]] && [[ "$(getenforce)" != "disabled" ]]; then
      chcon -Rv --type=httpd_sys_rw_content_t "${install_path}/bootstrap/cache/"
      chcon -Rv --type=httpd_sys_rw_content_t "${install_path}/config/"
      chcon -Rv --type=httpd_sys_rw_content_t "${install_path}/storage/"
    fi
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    chown -R www-data:www-data "${install_path}"
  fi
}

echo "######################################################################"
echo
echo "                  !!  Use at your own risk !!                         "
echo
echo " This script is intended to be used on a new server that has not "
echo " been previously modified in any way."
echo
echo " Press CTRL+C to cancel if you're not sure if you want to proceed."
echo
echo "######################################################################"

if ((is_docker == 0)); then
  sleep 10
fi

identify_os
check_root
detect_supportpal
setup

install_mysql
install_apache
install_supportpal

echo "######################################################################"
echo
echo " Successfully installed dependencies."
echo
echo "######################################################################"
echo
echo " You can now open your web browser to the following address and run"
echo " the SupportPal installer."
echo
echo " http://$(curl -s https://api.ipify.org)/"
echo
echo " Directories"
echo "   SupportPal: /var/www/supportpal"
echo "   Logs:       /var/log/supportpal"
echo
echo " MySQL"
echo "   Root Password: ${root_password}"
echo "   Database name: ${database}"
echo "   Username:      ${username}"
echo "   Password:      ${user_password}"
echo
echo "######################################################################"
