#!/bin/bash
set -eu -o pipefail

usage="Usage: bash $0 [options] -- example.com www.example.com

Options:
    --help                  Display this help and exit.
"

while [[ "$#" -gt 0 ]]; do
  case $1 in
  --help) echo "$usage" ; exit 0 ;;
  --) shift ; break ;;
  *) echo "Unknown parameter passed: $1" >&2 ; exit 1 ;;
  esac
  shift
done

domains=( "$@" )
rsa_key_size=4096
data_path="./ssl/certbot"

if [ "${#domains[@]}" -lt "1" ]; then
  echo "Error: expected 1 or more domains, ${#domains[@]} provided."  >&2
  exit 1
fi

if ! [ -x "$(command -v docker compose)" ]; then
  echo 'Error: docker compose is not installed.' >&2
  exit 1
fi

if [ -d "$data_path" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

echo "### Creating dummy certificate for $domains ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$data_path/conf/live/$domains"
docker compose -f docker-compose.yml -f docker-compose.https.yml run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo
