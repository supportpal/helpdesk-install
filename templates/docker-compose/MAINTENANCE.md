# Backup and Restore

> :large_blue_circle: All commands must be run in a bash compatible terminal. If you're on Windows, use Git Bash.

## Backup

> :large_blue_circle: Please fetch the latest Git repository changes before running the command (`git pull`).

```bash
make backup
```

## Restore

> :large_blue_circle: Please fetch the latest Git repository changes before running the command (`git pull`).

```bash
make restore
```

----

# Upgrading SupportPal

> :large_blue_circle: All commands must be run in a bash compatible terminal. If you're on Windows, use Git Bash.

1. Take a full backup:
   ```bash
   make backup
   ```
2. Run the `upgrade` command:
   ```bash
   make upgrade
   ```
   
   > :warning: **Upgrades from v4.x to v5**
   > 
   > You will receive an error after running the `docker exec -it -u www-data $(WEB_SERVICE_NAME) bash -c '/usr/local/bin/php artisan app:upgrade --confirm-backup'`
   > command. Run `make upgrade` again to resolve the issue.
