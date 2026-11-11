#!/bin/bash
# Oracle OPS Installer library: output, logging, child processes, ending a run, prompts, validation helpers
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---------------------------------------------------------------------------------------------------------------------------
# Output and protected logging
# ---------------------------------------------------------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Removes secrets and terminal control sequences from a stream before it reaches the log: the literal token (bash
# expansion, so the token never becomes an argument of another program), anything shaped like a GitHub token, the
# user-info part of URLs (proxy or credential-bearing URLs), ANSI escape sequences and other control characters.
sanitize_stream() {
  local line esc
  esc="$(printf '\033')"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$TOKEN" ]; then line="${line//"$TOKEN"/[REDACTED]}"; fi
    if [ -n "$API_KEY_REDACT_1" ]; then line="${line//"$API_KEY_REDACT_1"/[REDACTED]}"; fi
    if [ -n "$API_KEY_REDACT_2" ]; then line="${line//"$API_KEY_REDACT_2"/[REDACTED]}"; fi
    if [ -n "$OWNER_PW" ]; then line="${line//"$OWNER_PW"/[REDACTED]}"; fi
    printf '%s\n' "$line"
  done | sed -r \
      -e "s/${esc}\\[[0-9;?]*[A-Za-z]//g" \
      -e 's/gh[pousr]_[A-Za-z0-9]{16,}/[REDACTED]/g' \
      -e 's/github_pat_[A-Za-z0-9_]{16,}/[REDACTED]/g' \
      -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    | tr -d '\000-\010\013-\037\177'
}

log() {
  [ -n "$LOG_FILE" ] || return 0
  printf '%s %s\n' "$(now_utc)" "$*" | sanitize_stream >> "$LOG_FILE" 2>/dev/null || true
}

stage() {
  say "[$1/$STAGE_TOTAL] $2"
  log "== stage $1/$STAGE_TOTAL: $2"
}

# run_quiet <description> <command...>: stdin closed, all output to the protected log (sanitized). The raw output stays in
# $CAPTURE (inside the root-only run directory) until the next call, for failure classification. Returns the status.
run_quiet() {
  local desc="$1" rc=0
  shift
  [ -n "$RUN_DIR" ] || finish 1 "internal error: no staging directory"
  log "run: $desc"
  CAPTURE="$RUN_DIR/capture.out"
  "$@" < /dev/null > "$CAPTURE" 2>&1 || rc=$?
  sanitize_stream < "$CAPTURE" | sed 's/^/    | /' >> "$LOG_FILE" || log "WARNING: the output of '$desc' could not be written to the log"
  log "exit status $rc: $desc"
  return "$rc"
}

# run_interactive <description> <command...>: an Oracle OPS tool that talks to the operator. It keeps the terminal on
# stdin; its output is shown AND recorded (sanitized) in the log afterwards. Returns the tool's status.
run_interactive() {
  local desc="$1" rc=0 out="$RUN_DIR/interactive.out"
  shift
  [ -n "$RUN_DIR" ] || finish 1 "internal error: no staging directory"
  log "run (interactive, shown to the operator): $desc"
  : > "$out"
  if "$@" 2>&1 | tee -a "$out"; then rc=0; else rc="${PIPESTATUS[0]}"; fi
  sanitize_stream < "$out" | sed 's/^/    | /' >> "$LOG_FILE" || log "WARNING: the output of '$desc' could not be written to the log"
  rm -f -- "$out"
  log "exit status $rc: $desc"
  return "$rc"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Child processes: a scrubbed environment, never the token
# ---------------------------------------------------------------------------------------------------------------------------

# Only ever called inside a subshell: removes every exported variable except ENV_KEEP (so BASH_ENV, GIT_*, JAVA_*,
# LD_* and the like cannot reach a child), sets PATH/HOME/LC_ALL, then replaces the subshell with the command. Building
# the environment here, rather than with `env NAME=value`, keeps values such as proxy URLs out of any argument list.
CHILD_HOME=""
clean_env_exec() {
  local v
  for v in $(compgen -e); do
    case " $ENV_KEEP " in *" $v "*) ;; *) unset "$v" 2>/dev/null || true ;; esac
  done
  export PATH="$SAFE_PATH" HOME="$CHILD_HOME" LC_ALL=C
  exec "$@"
}

# The installer's own environment gets the same treatment at start-up, so the commands it runs directly (systemctl, unzip,
# yum, ...) inherit only ENV_KEEP too. sudo normally resets the environment already; this also covers a root login shell.
scrub_environment() {
  local v
  for v in $(compgen -e); do
    case " $ENV_KEEP " in *" $v "*) ;; *) unset "$v" 2>/dev/null || true ;; esac
  done
  export PATH="$SAFE_PATH" LC_ALL=C
}

# git_net <timeout> <git arguments...>: a network git command authenticated only through the askpass helper. HOME is an
# empty directory and GIT_CONFIG_NOSYSTEM=1, so no user or system git configuration (and no credential helper that could
# store the token) is read; the user's git configuration and credentials are never touched.
git_net() {
  local t="$1"
  shift
  ( CHILD_HOME="$RUN_DIR/githome"
    export GIT_ASKPASS="$AUTH_DIR/askpass" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    ENV_KEEP="$ENV_KEEP GIT_ASKPASS GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT"
    clean_env_exec timeout --foreground "$t" git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 -c transfer.fsckObjects=true "$@" )
}

# git_local <git arguments...>: a local git command inside the staged source (no network, no askpass).
git_local() {
  ( cd "$OPS_SRC" || exit 1
    CHILD_HOME="$RUN_DIR/githome"
    export GIT_CONFIG_NOSYSTEM=1
    ENV_KEEP="$ENV_KEEP GIT_CONFIG_NOSYSTEM"
    clean_env_exec git "$@" )
}

# ops_run <script> <arguments...>: an Oracle OPS script from the staged, verified release, with the umask Oracle OPS
# expects of root (022) and no TMPDIR (its database check stages files in /tmp for the service account).
ops_run() {
  local script="$1"
  shift
  ( umask 022
    CHILD_HOME="$ROOT_HOME"
    clean_env_exec bash "$OPS_SRC/deploy/scripts/$script" "$@" )
}

# pkg_run <packages...>: the operating system's package manager with a fixed command; the package names come only from
# tool_package() below, never from input.
pkg_run() {
  ( CHILD_HOME="$ROOT_HOME"
    clean_env_exec timeout --foreground "$PKG_TIMEOUT" yum -y install "$@" )
}

# ---------------------------------------------------------------------------------------------------------------------------
# Ending a run: one exit path, cleanup always attempted, the primary outcome never replaced by a cleanup problem
# ---------------------------------------------------------------------------------------------------------------------------

finish() {   # finish <exit status> [reason]
  FAIL_REASON="${2:-}"
  exit "$1"
}

die_early() {  # before logging exists: a short message, no secret, no log reference
  printf 'Oracle OPS Installer: %s\n' "$1" >&2
  exit "$2"
}

# Removes a directory only if it is exactly the path this run recorded, is a real directory and carries this run's marker.
remove_own_dir() {
  local d="$1"
  [ -n "$d" ] || return 0
  [ -e "$d" ] || [ -L "$d" ] || return 0
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -f "$d/$MARKER_NAME" ]; then
    CLEANUP_PROBLEMS="$CLEANUP_PROBLEMS $d"
    log "cleanup: NOT removing $d (not a directory carrying this run's marker)"
    return 0
  fi
  if rm -rf --one-file-system -- "$d" && [ ! -e "$d" ]; then
    log "cleanup: removed $d"
  else
    CLEANUP_PROBLEMS="$CLEANUP_PROBLEMS $d"
    log "cleanup: FAILED to remove $d"
  fi
}

destroy_auth() {
  if [ -n "$AUTH_DIR" ]; then
    rm -f -- "$AUTH_DIR/token" 2>/dev/null || true
    [ ! -e "$AUTH_DIR/token" ] || CLEANUP_PROBLEMS="$CLEANUP_PROBLEMS $AUTH_DIR/token"
    remove_own_dir "$AUTH_DIR"
    case " $CLEANUP_PROBLEMS " in *" $AUTH_DIR "*) ;; *) AUTH_DIR="" ;; esac
  fi
  TOKEN=""
}

cleanup() {
  destroy_auth
  if [ -n "$RUN_DIR" ]; then
    remove_own_dir "$RUN_DIR"
    case " $CLEANUP_PROBLEMS " in *" $RUN_DIR "*) ;; *) RUN_DIR="" ;; esac
  fi
}

report() {
  local rc="$1" what="Oracle OPS $OPERATION"
  log "outcome: exit status $rc${FAIL_REASON:+ — $FAIL_REASON}"
  case "$rc" in
    0)
      [ -z "$SUCCESS_TEXT" ] || { echo; printf '%s\n' "$SUCCESS_TEXT"; }
      ;;
    5)
      echo; say "Cancelled${FAIL_REASON:+: $FAIL_REASON}."
      ;;
    6)
      echo; say "${FAIL_REASON:-This action does not apply to this host}."
      say "Nothing was changed."
      ;;
    129|130|143)
      echo; say "$what was interrupted."
      ;;
    *)
      echo; say "$what failed."
      [ -z "$FAIL_REASON" ] || say "Reason: $FAIL_REASON."
      ;;
  esac
  if [ "$rc" != 0 ] && [ -n "$LOG_FILE" ]; then
    echo
    say "Review the administrator installation log for details:"
    say "  $LOG_FILE"
  elif [ "$rc" = 0 ] && [ -n "$LOG_FILE" ] && [ -n "$SUCCESS_TEXT" ]; then
    say "Installation log: $LOG_FILE"
  fi
  if [ -n "$CLEANUP_PROBLEMS" ]; then
    log "WARNING: cleanup incomplete:$CLEANUP_PROBLEMS"
    echo
    say "Warning: temporary installer files could not be removed:$CLEANUP_PROBLEMS"
    say "Remove them as root after review. They may contain the private Oracle OPS source."
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  if stdin_is_tty; then stty echo 2>/dev/null; fi
  cleanup
  report "$rc"
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------------------------------------------------------

read_line() {  # read_line <variable>: one trimmed line from stdin; false at end of input
  local _l
  IFS= read -r _l || return 1
  _l="${_l#"${_l%%[![:space:]]*}"}"
  _l="${_l%"${_l##*[![:space:]]}"}"
  printf -v "$1" '%s' "$_l"
}

# confirm_yes <question>: true only for "yes" (any case). Anything else, or the end of input, is a no.
confirm_yes() {
  local a
  printf '      %s Type "yes" to continue: ' "$1"
  read_line a || { echo; return 1; }
  [ "$(printf '%s' "$a" | tr 'A-Z' 'a-z')" = "yes" ]
}

# choose <variable> <prompt> <allowed values...>: up to three attempts.
choose() {
  local var="$1" prompt="$2" a v attempt
  shift 2
  for attempt in 1 2 3; do
    printf '%s' "$prompt"
    read_line a || { echo; finish 5 "no choice was entered"; }
    for v in "$@"; do
      if [ "$a" = "$v" ]; then printf -v "$var" '%s' "$a"; return 0; fi
    done
    say "      Please enter one of: $*"
  done
  finish 2 "no valid choice after three attempts"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Validation helpers (Oracle OPS validates everything again; these keep the installer's own decisions safe)
# ---------------------------------------------------------------------------------------------------------------------------

valid_home() {
  local h="$1" f
  [[ "$h" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [ "${#h}" -le 200 ] || return 1
  case "$h/" in */../*|*/./*|*//*) return 1 ;; esac
  for f in $HOME_FORBIDDEN; do
    [ "$h" != "$f" ] || return 1
    [ "$f" = "/" ] || case "$h/" in "$f"/*) return 1 ;; esac
  done
  return 0
}

valid_account_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.@-]{0,63}$ ]]; }

commit_matches_pin() {  # the build stamps an abbreviated commit id (at least 7 hex digits)
  [[ "$1" =~ ^[0-9a-f]{7,40}$ ]] && [ "${OPS_COMMIT#"$1"}" != "$OPS_COMMIT" ]
}

host_platform() {
  local id ver
  [ -r "$OS_RELEASE_FILE" ] || { echo "unknown"; return 0; }
  id="$(sed -n 's/^ID=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d '"'"'")"
  ver="$(sed -n 's/^VERSION_ID=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d '"'"'")"
  printf '%s:%s' "${id:-unknown}" "${ver%%.*}"
}

in_list() {  # in_list <word> <comma/space separated list>
  local w
  for w in ${2//,/ }; do [ "$w" = "$1" ] && return 0; done
  return 1
}
