#!/bin/bash
set -eu -o pipefail

version="0.0.1"

supported="The following Linux OSs are supported, on x86_64 only:
    * RHEL/CentOS 7 & 8 (rhel)
    * Ubuntu 18.04 LTS (bionic), & 20.04 LTS (focal)
    * Debian 9 (stretch) & 10 (buster)"

usage="Usage: curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/linux/setup.sh | sudo bash

$supported

Options:
    --help                  Display this help and exit.

    --version               Output the script version and exit.

    --docker                Use for testing purposes only; replaces systemd to allow testing in docker containers.
"

# whether running in docker container
is_docker=
# os_type = ubuntu, debian, rhel, sles
os_type=
# os_version as demanded by the OS (codename, major release, etc.)
os_version=
# ip address
ip=
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
socket_path='/var/run/php-fpm/supportpal.sock'

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
    5*)
      os_version=5
      error "RHEL/CentOS 5 is no longer supported" "$supported"
      ;;
    6*)
      os_version=6
      error "RHEL/CentOS 6 is no longer supported" "$supported"
      ;;
    7*) os_version=7 ;;
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

backup() {
  if [[ -e "$1" ]]; then
    i=1
    while [[ -e "$1.old_$i" || -L "$1.old_$i" ]]; do
      ((i++))
    done

    cp "$1" "$1.old_$i"
  fi
}

install() {
  if [[ $os_type == 'rhel' ]]; then
    yum install -y "$@"
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
  set +e
  if ((os_version == 7)); then
    yum install -y "$@"
  fi
  if ((os_version == 8)); then
    dnf install -y "$@"
  fi
  set -e
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

    install curl python3
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

setup() {
  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    export DEBIAN_FRONTEND=noninteractive
  fi
}

#
# PHP
#

configure_php_fpm() {
  mkdir -p "$(dirname "$socket_path")" && touch "$socket_path"

  echo "[supportpal]

listen = ${socket_path}
listen.allowed_clients = 127.0.0.1
listen.owner = $1
listen.group = $1
listen.mode = 0666

user = $1
group = $1

pm = ondemand
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.process_idle_timeout = 10s
pm.max_requests = 500

php_admin_value[error_log] = ${log_path}/php-fpm-error.log
php_admin_value[log_errors] = on
" > "$2"
}

install_php_rhel() {
  # Remove . from php_version
  local stripped_version=${php_version//\./}

  if ((os_version == 7)); then
    install_rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    install_rpm https://rpms.remirepo.net/enterprise/remi-release-7.rpm
    yum -y install yum-utils
    yum-config-manager --disable 'remi-php*' && yum-config-manager --enable "remi-php${stripped_version}"
    yum-config-manager --enable "remi-php${stripped_version}"
    yum -y install php php-fpm php-bcmath php-gd php-mbstring php-mysql php-xml php-imap php-ldap
  fi

  if ((os_version == 8)); then
    install_rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
    install_rpm https://rpms.remirepo.net/enterprise/remi-release-8.rpm
    dnf -y module reset php && dnf -y module enable "php:remi-${php_version}"
    dnf -y install php php-fpm php-bcmath php-gd php-mbstring php-mysql php-xml php-imap php-ldap
  fi

  configure_php_fpm apache /etc/php-fpm.d/supportpal.conf

  systemd restart php-fpm
}

install_php_deb() {
  apt-get -y install apt-transport-https lsb-release ca-certificates curl gnupg2

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
    "php${php_version}-curl" "php${php_version}-bcmath" "php${php_version}-ldap" "php${php_version}-imap"

    configure_php_fpm www-data "/etc/php/${php_version}/fpm/pool.d/supportpal.conf"

    FPM_PATH='/run/php/php7.4-fpm.sock'
    mkdir -p "$(dirname "$FPM_PATH")" && touch "$FPM_PATH"

    systemd start "php${php_version}-fpm"
  fi

  install_ioncube
}

install_ioncube() {
  # Get PHP extension directory.
  PHP_EXT_DIR=$(php -i | grep ^extension_dir | awk -F '=> ' '{print $3}')
  [[ "${PHP_EXT_DIR}" != */ ]] && PHP_EXT_DIR="${PHP_EXT_DIR}/"

  # Install Ioncube Loaders
  install curl
  IONCUBE_EXT="zend_extension = "${PHP_EXT_DIR}ioncube_loader_lin_${php_version}.so""
  curl -O http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
  tar xvfz ioncube_loaders_lin_x86-64.tar.gz
  cp "ioncube/ioncube_loader_lin_${php_version}.so" "${PHP_EXT_DIR}"

  if [[ $os_type == 'rhel' ]]; then
    # Remove . from php_version
    local stripped_version=${php_version//\./}

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

ip() {
  ip=$(curl -s https://api.ipify.org)
}

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
  firewall-cmd --add-service=http --permanent && firewall-cmd --reload

  backup /etc/httpd/conf.d/welcome.conf
  rm /etc/httpd/conf.d/welcome.conf

  write_vhost /etc/httpd/conf.d/supportpal.conf

  systemd restart httpd
}

install_apache_deb() {
  install apache2
  a2enmod rewrite proxy_fcgi

  write_vhost /etc/apache2/sites-available/supportpal.conf
  ln -s /etc/apache2/sites-available/supportpal.conf /etc/apache2/sites-enabled/supportpal.conf
  unlink /etc/apache2/sites-enabled/000-default.conf

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
  openssl rand -base64 14
}

install_mysql() {
  msg "info" "Installing MySQL..."

  install openssl
  root_password="$(generate_password)"
  user_password="$(generate_password)"

  if [[ $os_type == 'rhel' ]]; then
    if ((os_version == 7)); then
      install_rpm https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm
    fi

    if ((os_version == 8)); then
      install_rpm https://dev.mysql.com/get/mysql80-community-release-el8-1.noarch.rpm
      yum -y module disable mysql
    fi
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    install wget debconf-utils lsb-release gnupg2
    debconf-set-selections <<< "mysql-apt-config mysql-apt-config/select-product select Ok"
    debconf-set-selections <<< "mysql-server mysql-server/root_password password ${root_password}"
    debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${root_password}"

    wget -O mysql-apt-config.deb https://repo.mysql.com/mysql-apt-config_0.8.13-1_all.deb
    dpkg -i mysql-apt-config.deb && apt-get update
    rm mysql-apt-config.deb
  fi

  if [[ $os_type == 'rhel' ]]; then
    install mysql-community-server
    systemd restart mysqld

    TMP_PASS=$(grep "A temporary password is generated" /var/log/mysqld.log | awk '{print $NF}')
    mysql --connect-expired-password -u"root" -p"$TMP_PASS" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$root_password'; UNINSTALL COMPONENT 'file://component_validate_password';"
  fi

  if [[ $os_type == 'debian' ]] || [[ $os_type == 'ubuntu' ]]; then
    install mysql-server
    systemd restart mysql
  fi

  mysql -u"root" -p"$root_password" -e "CREATE DATABASE ${database}; CREATE USER '${username}'@'localhost' IDENTIFIED BY '$user_password'; GRANT ALL PRIVILEGES ON ${username}.* TO '${database}'@'localhost'; FLUSH PRIVILEGES;"
}

install_supportpal() {
  if [ -n "$(ls -A $install_path)" ]; then
    error "Unable to install SupportPal, ${install_path} already contains files. Please ensure the directory is empty."
  fi

  install jq unzip
  SP_VERSION=$(curl -s https://licensing.supportpal.com/api/version/latest.json | jq -r ".version")
  curl "https://www.supportpal.com/manage/downloads/supportpal-$SP_VERSION.zip" -o /tmp/supportpal.zip
  unzip /tmp/supportpal.zip -d "${install_path}"
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
ip
setup

update
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
echo " http://$ip/"
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
