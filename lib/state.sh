#!/bin/bash
# Oracle OPS Installer library: protected log, lock and staging directory
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---------------------------------------------------------------------------------------------------------------------------
# Start-up: protected log, lock, staging directory
# ---------------------------------------------------------------------------------------------------------------------------

# ensure_private_dir <dir>: <dir> must be (or is created as) a real directory owned by the administrative account, mode
# 0700, under a parent owned by that account and not writable by group or other. Nothing is followed through a link.
ensure_private_dir() {
  local d="$1" p mode
  p="$(dirname "$d")"
  if [ ! -d "$p" ] || [ -L "$p" ] || [ "$(stat -c %u "$p")" != "$ADMIN_UID" ]; then
    echo "$p must be a real directory owned by root"; return 1
  fi
  mode="$(stat -c %a "$p")"
  if [ $((8#$mode & 8#022)) -ne 0 ]; then echo "$p is writable by group or other users (mode $mode)"; return 1; fi
  if [ -L "$d" ]; then echo "$d is a symbolic link"; return 1; fi
  if [ -e "$d" ]; then
    [ -d "$d" ] || { echo "$d exists and is not a directory"; return 1; }
    [ "$(stat -c %u "$d")" = "$ADMIN_UID" ] || { echo "$d is not owned by root"; return 1; }
    chmod 0700 "$d" || { echo "cannot set the mode of $d"; return 1; }
  else
    mkdir -m 0700 "$d" || { echo "cannot create $d"; return 1; }
  fi
}

init_logging() {
  local msg stamp
  msg="$(ensure_private_dir "$LOG_DIR")" || die_early "cannot use the log directory: $msg. Resolve this as root, then run the installer again." 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_FILE="$LOG_DIR/oracle-ops-installer-$stamp-$$.log"
  ( umask 077; : > "$LOG_FILE" ) || die_early "cannot create the log file in $LOG_DIR" 1
  chmod 0600 "$LOG_FILE"
  log "Oracle OPS Installer $INSTALLER_VERSION; pinned Oracle OPS $OPS_VERSION ($OPS_COMMIT); pid $$"
  prune_logs
}

# Keeps the newest LOG_KEEP installer logs; only regular files with this installer's own name pattern are ever removed.
prune_logs() {
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -gt "$LOG_KEEP" ] || continue
    case "$f" in oracle-ops-installer-[0-9]*T[0-9]*Z-[0-9]*.log) ;; *) continue ;; esac
    if [ -f "$LOG_DIR/$f" ] && [ ! -L "$LOG_DIR/$f" ]; then rm -f -- "$LOG_DIR/$f" && log "removed old log $f"; fi
  done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -name 'oracle-ops-installer-*.log' -printf '%f\n' | sort -r)
}

# The state directory holds only the lock file and this installer's run directories. Every run.* carrying the marker is
# a leftover of an interrupted run (the lock proves no other run is active) and is removed; anything else stops the run.
init_state() {
  local msg e
  msg="$(ensure_private_dir "$STATE_DIR")" || finish 1 "cannot use the staging directory: $msg (resolve this as root after review)"
  exec {LOCK_FD}>>"$STATE_DIR/.lock" || finish 1 "cannot open the lock file in $STATE_DIR"
  flock -n "$LOCK_FD" || finish 1 "another run of the Oracle OPS Installer is in progress"
  while IFS= read -r e; do
    case "$e" in
      .lock) ;;
      run.*)
        if [ -d "$STATE_DIR/$e" ] && [ ! -L "$STATE_DIR/$e" ] && [ -f "$STATE_DIR/$e/$MARKER_NAME" ]; then
          log "removing the staging directory of an earlier, interrupted run: $STATE_DIR/$e"
          rm -rf --one-file-system -- "${STATE_DIR:?}/$e" || finish 1 "cannot remove the leftover staging directory $STATE_DIR/$e"
        else
          finish 1 "unexpected entry $STATE_DIR/$e (not created by this installer). Review and remove it as root, then run the installer again"
        fi ;;
      *) finish 1 "unexpected entry $STATE_DIR/$e (not created by this installer). Review and remove it as root, then run the installer again" ;;
    esac
  done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n')
  # Leftover token directories of interrupted runs (only ours: marker present; /run is emptied at every boot anyway).
  ensure_private_dir_parent_ok "$AUTH_BASE" && while IFS= read -r e; do
    if [ -d "$e" ] && [ ! -L "$e" ] && [ -f "$e/$MARKER_NAME" ]; then
      rm -rf --one-file-system -- "$e" && log "removed a leftover token directory of an interrupted run: $e"
    fi
  done < <(find "$AUTH_BASE" -mindepth 1 -maxdepth 1 -name 'oracle-ops-installer.*' -print 2>/dev/null)
  RUN_DIR="$(mktemp -d "$STATE_DIR/run.XXXXXXXX")" || finish 1 "cannot create a staging directory in $STATE_DIR"
  printf '%s %s %s\n' "$MARKER_TEXT" "$BASHPID" "$(now_utc)" > "$RUN_DIR/$MARKER_NAME"
  mkdir -m 0700 "$RUN_DIR/githome"
  log "staging directory: $RUN_DIR"
}

# /run must be owned by root and not writable by group/other for the token directory to go there.
ensure_private_dir_parent_ok() {
  local mode
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = "$ADMIN_UID" ] || return 1
  mode="$(stat -c %a "$1")"
  [ $((8#$mode & 8#022)) -eq 0 ]
}
