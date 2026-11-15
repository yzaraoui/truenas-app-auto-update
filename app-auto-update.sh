#!/bin/bash
###############################################################################
# TrueNAS App Auto-Updater (app-auto-update.sh)
#
# What it does:
#   1. Finds every app that has an update available.
#   2. RUNNING apps  -> upgrade, they stay running.
#   3. STOPPED apps  -> start, upgrade, then stop again (back to STOPPED).
#   4. Apps in any other state are skipped.
#   5. If at least one app was upgraded, clean up old Docker images.
#   6. Writes a timestamped log and a summary at the end of each run.
#
# Run as root or as the admin user of the web UI. Needs: midclt, jq, docker.
###############################################################################


# ----------------------------- SETTINGS --------------------------------------

# Apps to never touch, separated by spaces. Example: EXCLUDE="plex immich"
EXCLUDE=""

# Max seconds to wait for an app to reach RUNNING or STOPPED.
TIMEOUT=300

# Image cleanup: dangling (safe) | all (also removes stopped apps' images) | none
PRUNE="dangling"

# Log file location. Keep it on a pool so it survives reboots.
# Replace YourPoolName with the name of your pool.
LOG_FILE="/mnt/YourPoolName/scripts/app-update.log"

# Rotate the log when it exceeds this size (in bytes). 1048576 = 1 MB.
LOG_MAX_SIZE=1048576

# How many old rotated logs to keep (app-update.log.1, .2, ...).
LOG_KEEP=5

# Lock file that prevents two runs at the same time. It is kept next to the
# log so that the user running the script (root or admin) can always open it.
LOCK_FILE="$(dirname "$LOG_FILE")/.app-auto-update.lock"



# ----------------------------- LOGGING ---------------------------------------

# Rotate the log if it is too big: .log -> .log.1 -> .log.2 ... oldest deleted.
rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -ge "$LOG_MAX_SIZE" ]; then
    for ((i=LOG_KEEP-1; i>=1; i--)); do
      [ -f "$LOG_FILE.$i" ] && mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
    done
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

# log <LEVEL> <message...>
# Writes "2026-11-15 04:00:01 [INFO] message" to the screen and the log file.
log() {
  local level="$1"; shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOG_FILE"
}

# run <command...>
# Runs a command, writes its output to the log (indented), and returns the
# command's own exit code so the caller can check success or failure.
run() {
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if [ -n "$out" ]; then
    while IFS= read -r line; do
      echo "$(date '+%Y-%m-%d %H:%M:%S') [CMD]   $line" | tee -a "$LOG_FILE"
    done <<< "$out"
  fi
  return $rc
}


# ----------------------------- FUNCTIONS -------------------------------------

# state <app>: prints the current state of an app (RUNNING, STOPPED...).
state() {
  midclt call app.query "[[\"name\",\"=\",\"$1\"]]" | jq -r '.[0].state'
}

# wait_for <app> <wanted_state>: polls every 5 s until the state is reached.
# Returns an error after TIMEOUT seconds.
wait_for() {
  local i=0
  while [ "$(state "$1")" != "$2" ]; do
    sleep 5
    i=$((i+5))
    if [ $i -ge $TIMEOUT ]; then
      log ERROR "$1 did not reach $2 within ${TIMEOUT}s"
      return 1
    fi
  done
  log INFO "$1 is now $2"
}


# ----------------------------- START -----------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
rotate_log

# Prevent two runs at the same time (for example, cron starting while a
# manual run is still going). The lock is released when the script exits.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log WARN "Another run is already in progress, exiting"
  exit 1
fi

log INFO "=================== Run started ==================="

# Counters and lists used for the summary at the end.
UPGRADED=0
OK_LIST=""
FAIL_LIST=""
SKIP_LIST=""

# Get the apps that need an update. If this fails, stop here: there is
# nothing safe to do.
APPS=$(midclt call app.query | jq -r '.[] | select(.upgrade_available==true) | "\(.name) \(.state)"')
if [ $? -ne 0 ]; then
  log ERROR "Could not query apps from TrueNAS, aborting"
  exit 1
fi

if [ -z "$APPS" ]; then
  log INFO "No app updates available"
else
  log INFO "Apps with updates: $(echo "$APPS" | awk '{print $1"("$2")"}' | xargs)"
fi


# ----------------------------- MAIN LOOP -------------------------------------

while read -r app st; do
  [ -z "$app" ] && continue

  # Skip excluded apps.
  if [[ " $EXCLUDE " == *" $app "* ]]; then
    log INFO "$app: skipped (excluded)"
    SKIP_LIST="$SKIP_LIST $app"
    continue
  fi

  log INFO "$app: state is $st, starting"

  case "$st" in

    # Already running: just upgrade.
    RUNNING)
      if run midclt call -j app.upgrade "$app" '{}'; then
        log INFO "$app: upgraded (left RUNNING)"
        UPGRADED=1; OK_LIST="$OK_LIST $app"
      else
        log ERROR "$app: upgrade FAILED"
        FAIL_LIST="$FAIL_LIST $app"
      fi
      ;;

    # Stopped: start, upgrade, stop again.
    STOPPED)
      log INFO "$app: starting temporarily to allow the upgrade"
      if ! run midclt call -j app.start "$app" || ! wait_for "$app" RUNNING; then
        log ERROR "$app: could not start, skipping (left as is)"
        FAIL_LIST="$FAIL_LIST $app"
        continue
      fi

      if run midclt call -j app.upgrade "$app" '{}'; then
        log INFO "$app: upgraded"
        UPGRADED=1; OK_LIST="$OK_LIST $app"
      else
        log ERROR "$app: upgrade FAILED"
        FAIL_LIST="$FAIL_LIST $app"
      fi

      # Return the app to STOPPED whatever the upgrade result was.
      wait_for "$app" RUNNING
      log INFO "$app: stopping to restore original state"
      if run midclt call -j app.stop "$app" && wait_for "$app" STOPPED; then
        log INFO "$app: restored to STOPPED"
      else
        log ERROR "$app: could NOT be stopped, check manually"
      fi
      ;;

    # Any other state: do nothing.
    *)
      log WARN "$app: skipped (state $st)"
      SKIP_LIST="$SKIP_LIST $app"
      ;;
  esac

done <<< "$APPS"


# ----------------------------- IMAGE CLEANUP ---------------------------------

if [ "$UPGRADED" -eq 1 ]; then
  case "$PRUNE" in
    dangling)
      log INFO "Pruning dangling images"
      run docker image prune -f
      ;;
    all)
      log INFO "Pruning ALL unused images"
      run docker image prune -a -f
      ;;
    *)
      log INFO "Image prune disabled"
      ;;
  esac
fi


# ----------------------------- SUMMARY ---------------------------------------

log INFO "-------------------- Summary --------------------"
log INFO "Upgraded : ${OK_LIST:-none}"
log INFO "Failed   : ${FAIL_LIST:-none}"
log INFO "Skipped  : ${SKIP_LIST:-none}"
log INFO "=================== Run finished ==================="

# Exit code 1 if any app failed, so cron/monitoring can detect problems.
[ -z "$FAIL_LIST" ]
