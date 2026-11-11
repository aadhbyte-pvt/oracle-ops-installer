#!/bin/bash
# Oracle OPS Installer library: start-up and exit of the read-only checks (status, validate) started from the command line
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# The command-line path is the STRICT read-only path (docs/DEVELOPER.md, "Read-only checks"): its own log name, no pruning, no
# ensure_private_dir (no chmod of anything), no removal of leftovers, a SHARED lock. It may create: LOG_DIR / STATE_DIR when
# they are missing (mode 0700), the new check log, the lock file when it is missing, and (validate only) its own marked run
# directory, which is removed again on every exit path. The menu keeps today's start-up (init_logging, init_state) and adds
# only prune_check_logs below.

CHECK_DIR_NOTES=""        # warnings about the installer's own directories found by the strict start-up (reported by status)
CHECK_DIR_PROBLEM=""
CHECK_OWN_RUN_DIR=0
CHECK_SUMMARY_DONE=0
CHECK_RC=0

# prune_check_logs: the menu start-up keeps the newest CHECK_LOG_KEEP check logs; only regular files with the check-log name
# pattern are ever removed (installer logs are pruned by prune_logs, unchanged).
prune_check_logs() {
  local f n=0
  while IFS= read -r f; do
    case "$f" in oracle-ops-check-[0-9]*T[0-9]*Z-[0-9]*.log) ;; *) continue ;; esac
    n=$((n + 1))
    [ "$n" -gt "$CHECK_LOG_KEEP" ] || continue
    if [ -f "$LOG_DIR/$f" ] && [ ! -L "$LOG_DIR/$f" ]; then rm -f -- "$LOG_DIR/$f" && log "removed old check log $f"; fi
  done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -name 'oracle-ops-check-*.log' -printf '%f\n' | sort -r)
}

# check_dir_strict <dir> <description>: the strict rule for one of the installer's own directories. Sets CHECK_DIR_PROBLEM
# (non-empty = refuse) and appends warnings to CHECK_DIR_NOTES. An existing directory must be real (no link), owned by the
# administrative account and not writable by group or other; any other mode than 0700 is a warning, never changed. A missing
# directory is created with mode 0700 under a parent that is a real directory, owned by that account and not writable by
# group or other.
check_dir_strict() {
  local d="$1" what="$2" p mode own
  CHECK_DIR_PROBLEM=""
  if [ -L "$d" ]; then CHECK_DIR_PROBLEM="$what $d is a symbolic link"; return 0; fi
  if [ -e "$d" ]; then
    if [ ! -d "$d" ]; then CHECK_DIR_PROBLEM="$what $d exists and is not a directory"; return 0; fi
    if ! own="$(stat -c %u "$d" 2>/dev/null)"; then CHECK_DIR_PROBLEM="cannot examine $what $d"; return 0; fi
    if [ "$own" != "$ADMIN_UID" ]; then CHECK_DIR_PROBLEM="$what $d is not owned by root (owner uid $own)"; return 0; fi
    if ! mode="$(stat -c %a "$d" 2>/dev/null)"; then CHECK_DIR_PROBLEM="cannot examine $what $d"; return 0; fi
    if [ $((8#$mode & 8#022)) -ne 0 ]; then CHECK_DIR_PROBLEM="$what $d is writable by group or other users (mode $mode)"; return 0; fi
    if [ "$mode" != 700 ]; then
      CHECK_DIR_NOTES="${CHECK_DIR_NOTES:+$CHECK_DIR_NOTES; }$what $d has mode $mode, not 0700 (a read-only check does not change it; the menu start-up does)"
    fi
    return 0
  fi
  p="$(dirname "$d")"
  if [ ! -d "$p" ] || [ -L "$p" ]; then CHECK_DIR_PROBLEM="$p must be a real directory owned by root"; return 0; fi
  if ! own="$(stat -c %u "$p" 2>/dev/null)" || [ "$own" != "$ADMIN_UID" ]; then CHECK_DIR_PROBLEM="$p must be a real directory owned by root"; return 0; fi
  if ! mode="$(stat -c %a "$p" 2>/dev/null)"; then CHECK_DIR_PROBLEM="cannot examine $p"; return 0; fi
  if [ $((8#$mode & 8#022)) -ne 0 ]; then CHECK_DIR_PROBLEM="$p is writable by group or other users (mode $mode)"; return 0; fi
  if ! mkdir -m 0700 "$d" 2>/dev/null; then CHECK_DIR_PROBLEM="cannot create $what $d"; return 0; fi
  return 0
}

# check_start <mode>: the strict start-up. Creates the check log, then takes the SHARED lock (refused while an install, upgrade or
# de-installation holds the exclusive one). Exit 1 on any refusal, before anything else has been done.
check_start() {
  local stamp
  check_dir_strict "$LOG_DIR" "log directory"
  [ -z "$CHECK_DIR_PROBLEM" ] || die_early "cannot use the log directory: $CHECK_DIR_PROBLEM. Resolve this as root, then run the check again." 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_FILE="$LOG_DIR/oracle-ops-check-$stamp-$BASHPID.log"
  ( umask 077; set -C; : > "$LOG_FILE" ) || die_early "cannot create the log file in $LOG_DIR" 1
  log "Oracle OPS Installer $INSTALLER_VERSION: $1 (read-only); pinned Oracle OPS $OPS_VERSION ($OPS_COMMIT); pid $BASHPID"
  check_dir_strict "$STATE_DIR" "state directory"
  if [ -n "$CHECK_DIR_PROBLEM" ]; then
    log "refused: $CHECK_DIR_PROBLEM"
    die_early "cannot use the state directory: $CHECK_DIR_PROBLEM. Resolve this as root, then run the check again." 1
  fi
  if [ -L "$STATE_DIR/.lock" ]; then die_early "$STATE_DIR/.lock is a symbolic link" 1; fi
  exec {LOCK_FD}>>"$STATE_DIR/.lock" || die_early "cannot open the lock file in $STATE_DIR" 1
  flock -s -n "$LOCK_FD" || die_early "another run of the Oracle OPS Installer (an install, upgrade or de-installation) is in progress; try again when it has finished" 1
}

# check_new_run_dir: validate only. A run directory of its own in STATE_DIR (mode 0700) carrying the installer's marker (the pid of
# this process), so that an interrupted run is recognisable as a leftover.
check_new_run_dir() {
  RUN_DIR="$(mktemp -d "$STATE_DIR/run.XXXXXXXX")" || die_early "cannot create a staging directory in $STATE_DIR" 1
  CHECK_OWN_RUN_DIR=1
  printf '%s %s %s\n' "$MARKER_TEXT" "$BASHPID" "$(now_utc)" > "$RUN_DIR/$MARKER_NAME" || { rmdir "$RUN_DIR"; RUN_DIR=""; die_early "cannot write the marker of the staging directory" 1; }
  log "staging directory: $RUN_DIR"
}

# check_prepare_src: the directory the pinned files are extracted into (inside RUN_DIR).
check_prepare_src() {
  mkdir -m 0700 "$RUN_DIR/src"
}

# check_finish_run_dir: removes the check's own run directory now (it is also removed by check_on_exit on every other exit path);
# false if it is still there.
check_finish_run_dir() {
  [ -n "$RUN_DIR" ] || return 0
  remove_own_dir "$RUN_DIR"
  if [ -e "$RUN_DIR" ] || [ -L "$RUN_DIR" ]; then return 1; fi
  RUN_DIR=""
  return 0
}

# The exit path of a command-line check: the own run directory is removed whatever happened, an interrupted or aborted run is
# reported as a failure, and the exit status is never 0 after a problem.
check_on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  if [ -n "$RUN_DIR" ]; then
    remove_own_dir "$RUN_DIR"
    if [ -e "$RUN_DIR" ] || [ -L "$RUN_DIR" ]; then
      say "FAIL  run-directory: $RUN_DIR could not be removed; remove it as root after review"
      [ "$rc" != 0 ] || rc=1
    fi
  fi
  case "$rc" in
    129|130|143) say "The check was interrupted." ;;
    *)
      if [ "$CHECK_SUMMARY_DONE" != 1 ] && [ "$rc" != 6 ] && [ "$rc" != 2 ]; then
        say "FAIL  check: the run ended before it completed (exit status $rc)"
        [ "$rc" != 0 ] || rc=1
      fi ;;
  esac
  [ -z "$LOG_FILE" ] || log "outcome: exit status $rc"
  [ -z "$LOG_FILE" ] || say "Log: $LOG_FILE"
  exit "$rc"
}

# check_main <status|validate>: the command-line entry (never returns). Root is required (main has checked); no terminal.
check_main() {
  local t missing=""
  for t in $CHECK_BOOTSTRAP_TOOLS; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || die_early "basic system tools are missing:$missing" 3
  ROOT_HOME="$(root_home)"; ROOT_HOME="${ROOT_HOME:-/root}"
  export HOME="$ROOT_HOME"
  check_start "$1"
  trap check_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  SOURCE_REPO="${CLI_SOURCE_REPO:-$DEFAULT_SOURCE_REPO}"
  status_discover
  if [ "$CHECK_NOT_INSTALLED" = 1 ]; then
    say "Oracle OPS is not installed on this host (no $UNIT_FILE and no --home given). Nothing was changed."
    log "not installed"
    CHECK_SUMMARY_DONE=1
    exit 6
  fi
  if [ "$1" = validate ]; then
    check_new_run_dir
    validate_run
  else
    status_run
  fi
  exit "$CHECK_RC"
}
