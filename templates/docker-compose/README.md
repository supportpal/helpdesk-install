# Deploy SupportPal on Docker (Microservices)

Deploy SupportPal using a multi-node configuration with Docker Compose on GNU/Linux.
Experience with Docker is recommended.

# Prerequisites

Ensure your system meets our recommended [system requirements](https://docs.supportpal.com/current/System+Requirements). Operating system and
software requirements are already satisfied by our Docker containers.

## Linux 

* Install [Docker](https://docs.docker.com/engine/install/#server).
* Install the latest version of [Docker Compose](https://docs.docker.com/compose/install/#install-compose) (1.24 or greater).
* Install [Git](https://git-scm.com/downloads).
* Install GNU [Make](https://www.gnu.org/software/make/)

## MacOS

* Install [Docker Desktop](https://docs.docker.com/docker-for-mac/install/).
* Install [Git](https://git-scm.com/downloads).
* Install [Homebrew](https://brew.sh/).
* Install GNU [Make](https://formulae.brew.sh/formula/make) through homebrew:
  ```bash
  brew install make
  ```

## Windows

* Install [Docker Desktop](https://docs.docker.com/docker-for-windows/install/).
* Install [Git Bash](https://git-scm.com/downloads).
* Install [Chocolatey](https://chocolatey.org/install).
* Install GNU [Make](https://community.chocolatey.org/packages/make) through Chocolatey:
  ```bash
  choco install make
  ```

----

## Installation & Configuration

> :large_blue_circle: All commands must be run in a bash compatible terminal. If you're on Windows, use Git Bash.

### Install SupportPal

To start the installation, run the following:

**Linux / MacOS**
```bash
bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-compose/setup.sh)
```

**Windows**
```bash
winpty bash <(curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/docker-compose/setup.sh)
```

### Next Steps

Congratulations, you've successfully installed SupportPal!

You can control the state of the containers via the `make` command:
```bash
make help
```

We now recommend that you learn how to [administer](https://docs.supportpal.com/current/Administration) your installation.

----

## Customisation

> :warning: **Do not update any of the provided docker-compose files.**

In order to add customizations to the environment, Update the `Makefile` file, replacing the
`COMPOSE_FILES` variable:

```bash
COMPOSE_FILES=-f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.custom.yml
```

All updates should be done in your `docker-compose.custom.yml` file, refer to the
[compose file specifications](https://docs.docker.com/compose/compose-file/) or instructions later
in the setup.

### Configuring HTTPS

By default, the software will run on HTTP using port 80, however we recommend using HTTPS for added security.
To allow HTTPS, we provide an integration with LetsEncrypt, start the process with the following steps:

1. Change the current working directory to the `docker-compose` directory, for example:
    ```bash
    cd helpdesk-install/templates/docker-compose
    ```
2. Stop the containers if they are currently running:
   ```bash
   make stop
   ```
3. Update the `Makefile` file, by appending to the following string to `COMPOSE_FILES` variable, if the variable does
   not exist, copy its contents from Makefile.dist:
   ```bash
   -f docker-compose.https.yml
   ```
4. Add your help desk domain name to the `.env.custom` file. If you intend to use
   multiple domains / brands with your helpdesk, only specify one - it does not matter which one you choose.
   ```bash
   DOMAIN_NAME=example.com
   ```

You may now either set up a self-signed SSL certificate (if your domain is not available to the public),
or a full LetsEncrypt SSL certificate for your domain.

#### Self-Signed SSL Certificate

Execute the script, replacing the top level domain names with your own. You can list as many domain names as you need:
```bash
./../../configs/letsencrypt/create-self-signed.sh -- example.com www.example.com
```

#### LetsEncrypt SSL Certificate

> :warning: **Note** In order for this step to succeed, the domain name must be reachable for verification over port 80.

Execute the script, replacing the domain names and email address. You can list as many domain names as you need.
At least one of the domain names needs to be the `DOMAIN_NAME` specified in the `.env.custom` file.

```bash
./../../configs/letsencrypt/init-letsencrypt.sh --email user@company.com -- example.com www.example.com
```

Restart the containers for your changes to take effect:

```bash
make restart
```

### Configuring nginx

You can extend our default nginx configuration by making changes to
`templates/docker-compose/gateway/custom.conf` within the `helpdesk-install` repository.
See [https://nginx.org/en/docs/](https://nginx.org/en/docs/) for assistance with nginx config directives.

Restart the containers for your changes to take effect:

```bash
make restart
```

### Configuring PHP

You can extend our default PHP configuration by copying files into the containers.

1. Add PHP ini configuration files to the `templates/docker-compose/php/` directory. The configuration
   inside these files will be merged with the default configuration, overriding them on duplication.
   See [https://www.php.net/manual/en/configuration.file.php](https://www.php.net/manual/en/configuration.file.php)
   for assistance with PHP directives.
2. Restart the containers for your changes to take effect:
   ```bash
   make restart
   ```

### Extending SupportPal

It is easy to extend your SupportPal installation. Simply add your files to the relevant directory in the
`helpdesk-install` repository:

<table class="table">
    <tr>
        <th>Extension</th>
        <th><code>helpdesk-install</code> Directory</th>
    </tr>
    <tr>
        <td><a href="https://docs.supportpal.com/current/Plugin+Development">Creating plugins</a></td>
        <td>templates/docker-compose/customization/plugins</td>
    </tr>
    <tr>
        <td><a href="https://docs.supportpal.com/current/Custom+Reports">Creating reports</a></td>
        <td>templates/docker-compose/customization/reports</td>
    </tr>
    <tr>
        <td><a href="https://docs.supportpal.com/current/Language+Packs">Creating translations</a></td>
        <td>templates/docker-compose/customization/languages</td>
    </tr>
    <tr>
        <td><a href="https://docs.supportpal.com/current/Templates">Creating themes</a></td>
        <td>templates/docker-compose/customization/templates</td>
    </tr>
</table>

The changes should be immediately visible in your SupportPal installation without needing to restart the containers.

----

### Updating SupportPal config files

To create [SupportPal config files](https://docs.supportpal.com/current/Updating+Config+Files), simply
copy files from the host into the container. The example below copies `customization/saml.php`
from the host to a container called `supportpal`:

```bash
docker cp customization/saml.php supportpal:/supportpal/config/production/
```

For more complex tasks, such as updating or removing configuration files create an interactive shell and
administer it like a normal Linux machine:

```bash
docker compose exec supportpal bash
```

File changes in `config/production/` will persist restart events as the directory is
mounted as an external Docker volume.

### Using the migration script

To get started using the migration script follow the below steps:

1. Download and extract [migration script](https://docs.supportpal.com/current/Migration+Script)
2. Ensure the SupportPal docker containers are already running
3. In the directory where the migration script was extracted run:
   ```bash
   docker compose up -d
   ```
4. Access the migration script via `http` on port `8081` at the same hostname / IP
   address as the help desk. When finished with the migration script, run `docker compose down -v` to remove
   the container.
5. Configure Step 1
   1. Ensure the `storage/` directory is writable by the `www-data` user:
      ```bash
      docker compose exec migrations chown -R 33:33 storage/
      ```
   2. Set the database details:
      * Hostname: `db`
      * Name: `supportpal`
      * Username: can be found in `templates/docker-compose/secrets/db_user.txt`
      * Password: can be found in `templates/docker-compose/secrets/db_password.txt`
   3. Set the application details:
      * Storage Path: `/supportpal/storage`
      * Application Key: can be found in `config/production/app.php` within the `supportpal` container

----

## Uninstall

> :warning: This sequence of commands will permanently erase your installation, including the database data.

> :large_blue_circle: All commands must be run in a bash compatible terminal. If you're on Windows, use Git Bash.

To completely remove your help desk installation, follow the steps below:

1. Change the current working directory to the `docker-compose` directory, for example:
   ```bash
   cd helpdesk-install/templates/docker-compose
   ```
2. Take a [full backup](https://docs.supportpal.com/current/Backup+and+Restore).
3. Run the `uninstall` command:
   **Linux**
   ```bash
   sudo make uninstall
   ```

   **MacOS / Windows**
   ```bash
   make uninstall
   ```
