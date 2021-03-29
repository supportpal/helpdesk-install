SELF_FILENAME := $(word $(words $(MAKEFILE_LIST)),$(MAKEFILE_LIST))

include .env

DOCKER_BIN=docker
DOCKER_COMPOSE_BIN=docker-compose
CONFIGURATOR_VERSION=latest
COMPOSE_FILES=-f docker-compose.yml -f docker-compose.prod.yml

.DEFAULT_GOAL := help
.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(SELF_FILENAME) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: create_secrets create_volumes ## Install the help desk.
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) up -d $(GATEWAY_SERVICE_NAME) $(WEB_SERVICE_NAME) $(DATABASE_SERVICE_NAME) $(CACHE_SERVICE_NAME)
	$(DOCKER_BIN) exec -it $(WEB_SERVICE_NAME) su www-data -s /usr/local/bin/php artisan app:install

.PHONY: start
start: ## Start the help desk.
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) up -d

.PHONY: stop
stop: ## Stop the help desk.
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) stop

.PHONY: restart
restart: stop start ; ## Restart help desk.

.PHONY: create_volumes
create_volumes:
	$(DOCKER_BIN) volume create --name $(DB_VOLUME)
	$(DOCKER_BIN) volume create --name $(CONFIG_VOLUME)
	$(DOCKER_BIN) volume create --name $(STORAGE_VOLUME)
	$(DOCKER_BIN) volume create --name $(CACHE_VOLUME)
	$(DOCKER_BIN) volume create --name $(MAILER_VOLUME)

.PHONY: create_secrets
create_secrets:
	$(DOCKER_BIN) run -e SECRETS_DIR="$(SECRETS_DIR)" -v "$(SECRETS_DIR):/secrets" "public.ecr.aws/supportpal/helpdesk-configurator:$(CONFIGURATOR_VERSION)" sh "//app//scripts//create_secrets.sh"

