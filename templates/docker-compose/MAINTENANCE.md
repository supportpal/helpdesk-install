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
2. Edit `.env` and update the app version as necessary:
   ```text
   APP_VERSION=3.4.0
   ```
3. Run the `upgrade` command:
   ```bash
   make upgrade
   ```
