include .env

DOCKER_BIN=docker
DOCKER_COMPOSE_BIN=docker-compose
CONFIGURATOR_VERSION=latest
COMPOSE_FILES=-f docker-compose.yml -f docker-compose.prod.yml

install:
	$(MAKE) create_secrets
	$(MAKE) create_volumes
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) up -d $(GATEWAY_SERVICE_NAME) $(WEB_SERVICE_NAME) $(DATABASE_SERVICE_NAME) $(CACHE_SERVICE_NAME)

start:
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) up -d

stop:
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) stop

setup:
	$(DOCKER_BIN) exec -it $(WEB_SERVICE_NAME) su www-data -s /usr/local/bin/php artisan app:install

restart:
	$(MAKE) stop
	$(MAKE) start

create_volumes:
	$(DOCKER_BIN) volume create --name $(DB_VOLUME)
	$(DOCKER_BIN) volume create --name $(CONFIG_VOLUME)
	$(DOCKER_BIN) volume create --name $(STORAGE_VOLUME)
	$(DOCKER_BIN) volume create --name $(CACHE_VOLUME)
	$(DOCKER_BIN) volume create --name $(MAILER_VOLUME)

create_secrets:
	$(DOCKER_BIN) run -e SECRETS_DIR="$(SECRETS_DIR)" -v "$(SECRETS_DIR):/secrets" "public.ecr.aws/supportpal/helpdesk-configurator:$(CONFIGURATOR_VERSION)" sh "//app//scripts//create_secrets.sh"

