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

.PHONY: install_cli
install_cli: install_base ## Install the help desk using the CLI installer.
	$(DOCKER_BIN) exec -it -u www-data $(WEB_SERVICE_NAME) bash -c '/usr/local/bin/php artisan app:install'

.PHONY: install
install: install_base ## Install the helpdesk using the web installer.
	@printf "Open your web browser and complete the installation using the above database details."

.PHONY: start
start: ## Start the help desk.
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) up -d

.PHONY: stop
stop: ## Stop the help desk.
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) stop

.PHONY: restart
restart: stop start ## Restart help desk.

.PHONY: uninstall
uninstall: ## Irreversibly uninstall the help desk and all associated data.
	@printf "\033[0;33m|---------------------|\033[0m\n"
	@printf "\033[0;33m|       WARNING       |\033[0m\n"
	@printf "\033[0;33m|---------------------|\033[0m\n"
	@echo
	@printf "\033[0;33mThis action will irreversibly uninstall your help desk. This includes, but not limited to, permanent removal of the database and all user files.\033[0m\n"
	@printf "\033[0;33mDo NOT continue without a recent full system backup. You can take a backup of your system by executing: make backup\033[0m\n"
	@echo
	@printf "\033[0;33mPress CTRL + C to cancel this operation. Waiting 15 seconds...\033[0m\n"
	@sleep 15
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) down -v
	$(DOCKER_BIN) volume remove $(DB_VOLUME)
	$(DOCKER_BIN) volume remove $(CONFIG_VOLUME)
	$(DOCKER_BIN) volume remove $(STORAGE_VOLUME)
	$(DOCKER_BIN) volume remove $(CACHE_VOLUME)
	$(DOCKER_BIN) volume remove $(MAILER_VOLUME)
	rm -rf secrets

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

.PHONY: configure
configure:
	cp -n .env.dist .env || true
	cp -n docker-compose.yml.dist docker-compose.yml || true
	cp -n docker-compose.prod.yml.dist docker-compose.prod.yml || true
	cp -n -R ../../configs/gateway . || true

.PHONY: install_base
install_base: configure create_secrets create_volumes
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) up -d gateway supportpal db redis
	@echo
	@printf "Database Configuration:\n"
	@printf "\tHostname: db\n"
	@printf "\tPort: 3306\n"
	@printf "\tDatabase: supportpal\n"
	@printf "\tUsername: $$(cat secrets/db_user.txt)\n"
	@printf "\tPassword: $$(cat secrets/db_password.txt)\n"
	@echo

.PHONY: upgrade
upgrade: ## Upgrade SupportPal to a later version.
	@printf "\033[0;33m|---------------------|\033[0m\n"
	@printf "\033[0;33m|       NOTICE        |\033[0m\n"
	@printf "\033[0;33m|---------------------|\033[0m\n"
	@echo
	@printf "\033[0;33mThis action will upgrade your system to the specified APP_VERSION. We recommend that you only proceed if you've taken a recent full system backup.\033[0m\n"
	@printf "\033[0;33mYou can take a backup of your system by executing: make backup\033[0m\n"
	@echo
	@printf "\033[0;33mPress CTRL + C to cancel this operation. Waiting 10 seconds...\033[0m\n"
	@sleep 10
	$(DOCKER_COMPOSE_BIN) $(COMPOSE_FILES) down -v
	$(MAKE) start
	$(DOCKER_BIN) exec -it -u www-data $(WEB_SERVICE_NAME) bash -c '/usr/local/bin/php artisan app:upgrade --confirm-backup'

.PHONY: backup
backup: ## Create a full system backup.
	@ bash backup.sh
