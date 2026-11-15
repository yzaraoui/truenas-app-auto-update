# TrueNAS App Auto-Updater

A Bash script that automatically upgrades your TrueNAS apps, including apps you normally keep **stopped** and only start on demand.

- **Running apps** are upgraded and stay running.
- **Stopped apps** are started, upgraded, then stopped again, so they end up in their original state.
- Apps in any other state (deploying, crashed, ...) are skipped.
- Old Docker images are cleaned up after a successful upgrade (optional).
- Everything is written to a timestamped, auto-rotating log file with a summary at the end of each run.

TrueNAS cannot upgrade an app while it is stopped, which is why the script temporarily starts it.

## Requirements

- TrueNAS with the Apps feature (Docker-based apps), using the `midclt` middleware client
- `jq` (included in TrueNAS)
- `docker` (only needed for image cleanup)
- Must run as `root` or as the admin user of the web UI (see [Running as the admin user](#running-as-the-admin-user))

> The script uses the middleware API (`app.query`, `app.upgrade`, `app.start`, `app.stop`). It is written for recent TrueNAS releases. Test it manually after a major TrueNAS upgrade, as API behavior can change between versions.

## Installation

1. Store the script on a pool dataset, not on the system disk. The system disk can be replaced during OS updates, while a pool path persists.

   ```bash
   mkdir -p /mnt/YourPoolName/scripts
   nano /mnt/YourPoolName/scripts/app-auto-update.sh   # paste the script
   chmod +x /mnt/YourPoolName/scripts/app-auto-update.sh
   ```

   Replace `YourPoolName` with the name of your pool.

2. Edit the settings at the top of the script (see [Configuration](#configuration)).

3. Test it manually:

   ```bash
   bash -x /mnt/YourPoolName/scripts/app-auto-update.sh
   ```

4. Add a cron job in the TrueNAS UI under **System > Advanced Settings > Cron Jobs > Add**:

   | Field | Value |
   |---|---|
   | Command | `bash /mnt/YourPoolName/scripts/app-auto-update.sh` |
   | Run As User | `root` (or your admin user, see below) |
   | Schedule | for example, daily at 04:00 |
   | Enabled | yes |

   The script writes its own log, so no output redirect is needed. Using `bash` in front of the path means it still runs if the dataset is mounted with no-exec.

## Configuration

All settings are at the top of the script.

| Variable | Default | Description |
|---|---|---|
| `EXCLUDE` | `""` | Space-separated app names to never touch, e.g. `"plex immich"` |
| `TIMEOUT` | `300` | Max seconds to wait for an app to reach RUNNING or STOPPED |
| `PRUNE` | `dangling` | Image cleanup mode, see below |
| `LOG_FILE` | `/mnt/YourPoolName/scripts/app-update.log` | Log file path (keep it on a pool) |
| `LOG_MAX_SIZE` | `1048576` | Rotate the log when it exceeds this size in bytes (1 MB) |
| `LOG_KEEP` | `5` | Number of rotated logs to keep |

### Image cleanup modes

| Mode | Behavior |
|---|---|
| `dangling` | Removes only untagged leftover images. Safe default. |
| `all` | Removes every image not used by a container. **This also deletes the images of your stopped apps**, which will be re-downloaded the next time you start them. |
| `none` | No cleanup. |

Cleanup only runs if at least one app was actually upgraded, and only after all apps are back in their original state.

## How it works

1. Queries all apps and selects those with `upgrade_available == true`.
2. For each app, depending on its state:
   - `RUNNING`: upgrade.
   - `STOPPED`: start, wait until running, upgrade, wait until running, stop, wait until stopped.
   - anything else: skip and log a warning.
3. Prunes old images according to `PRUNE`.
4. Logs a summary (upgraded / failed / skipped) and exits with an error code if any app failed, so cron can email you if you enable that option.

A lock file (`.app-auto-update.lock`, stored next to the log file) prevents two runs from overlapping.

## Running as the admin user

The script can run as `root` or as the admin user of the web UI. No `sudo` is needed for the admin user (tested on TrueNAS).

1. **Dataset permissions.** In **Datasets**, select the `scripts` dataset and open **Permissions > Edit**. Set **User** and **Group** to your admin user and its group (`truenas_admin` on newer releases, `admin` on older ones; check under **Credentials > Users**). Tick **Apply User** and **Apply Group**, set the mode to `755`, tick **Apply permissions recursively**, and save. The admin user needs write access because the script writes its log and lock file in this folder.
2. **Cron job.** Set **Run As User** to the admin user.
3. **Test it first.** Log in as the admin user and run the script by hand:

   ```bash
   bash -x /mnt/YourPoolName/scripts/app-auto-update.sh
   ```

Make sure the script file is not writable by other users.

## Checking for updates manually

List the apps that currently have an update available:

```bash
midclt call app.query | jq -r '.[] | select(.upgrade_available==true) | "\(.name)\t\(.state)\t\(.human_version)"'
```

## Logs

```bash
tail -n 50 /mnt/YourPoolName/scripts/app-update.log   # last lines
tail -f /mnt/YourPoolName/scripts/app-update.log      # follow a run live
```

Example output:

```
2026-11-15 04:00:01 [INFO] =================== Run started ===================
2026-11-15 04:00:03 [INFO] Apps with updates: photoprism(STOPPED) nextcloud(RUNNING)
2026-11-15 04:00:03 [INFO] photoprism: starting temporarily to allow the upgrade
2026-11-15 04:02:10 [INFO] photoprism: upgraded
2026-11-15 04:05:30 [INFO] Upgraded : photoprism nextcloud
2026-11-15 04:05:30 [INFO] Failed   : none
2026-11-15 04:05:30 [INFO] =================== Run finished ===================
```

## Troubleshooting

- **`bad interpreter` or `^M` errors**: the file has Windows line endings. Fix with `sed -i 's/\r$//' app-auto-update.sh`.
- **An app did not return to STOPPED**: check the log for an `ERROR` line for that app and stop it manually from the UI.
- **`docker: command not found` in cron**: use the full path `/usr/bin/docker` in the script.
- **Another run is already in progress**: a previous run is still going. Check for a running `app-auto-update.sh` process.
- **`Permission denied` on the log or lock file**: the dataset is not owned by the user running the script. Re-apply the permissions described above.

## Safety notes

- Take a snapshot of your apps dataset before the first automated run.
- Major version jumps can break an app. Add critical apps (databases, anything you depend on) to `EXCLUDE` and upgrade them manually.
- Use at your own risk. Test on a non-critical system first.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
