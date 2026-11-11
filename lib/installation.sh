#!/bin/bash
# Oracle OPS Installer library: the existing installation and its verification
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---------------------------------------------------------------------------------------------------------------------------
# The existing installation (read-only)
# ---------------------------------------------------------------------------------------------------------------------------

unit_value() { sed -n "s/^$1=//p" "$UNIT_FILE" 2>/dev/null | head -n 1; }
unit_home() { sed -n 's/^Environment=ORACLE_OPS_HOME=//p' "$UNIT_FILE" 2>/dev/null | head -n 1; }

current_release() {  # the version `current` selects, if it is a link into <home>/releases/
  local h="$1" target base
  [ -L "$h/current" ] || return 0
  target="$(readlink -f "$h/current" 2>/dev/null)" || return 0
  base="$(readlink -f "$h")/releases/"
  case "$target" in "$base"?*) target="${target#"$base"}"; [ "${target#*/}" = "$target" ] && printf '%s' "$target" ;; esac
}

jar_commit() {  # the commit stamped into a deployed release by Oracle OPS's build
  local jar="$1/releases/$2/oracle-ops.jar"
  [ -f "$jar" ] && [ ! -L "$jar" ] || return 0
  unzip -p "$jar" "$JAR_VERSION_ENTRY" 2>/dev/null | sed -n 's/^build\.gitCommit=//p' | head -n 1 | tr -d '\r'
}

describe_installation() {  # from the installed unit; sets INST_*
  INST_HOME="$(unit_home)"; INST_USER="$(unit_value User)"; INST_GROUP="$(unit_value Group)"
  INST_RELEASE=""; INST_COMMIT=""; INST_ACTIVE="no"
  valid_home "$INST_HOME" || { log "installed unit: unusable ORACLE_OPS_HOME '$INST_HOME'"; INST_HOME=""; return 0; }
  INST_RELEASE="$(current_release "$INST_HOME")"
  [ -z "$INST_RELEASE" ] || INST_COMMIT="$(jar_commit "$INST_HOME" "$INST_RELEASE")"
  if service_active; then INST_ACTIVE="yes"; fi
  log "installed: home=$INST_HOME user=$INST_USER group=$INST_GROUP release=${INST_RELEASE:-none} commit=${INST_COMMIT:-unknown} active=$INST_ACTIVE"
}

pinned_release_running() {
  [ "$INST_RELEASE" = "$OPS_VERSION" ] && commit_matches_pin "$INST_COMMIT" && [ "$INST_ACTIVE" = yes ]
}

# The installation the unit points to must exist; Update credentials, Upgrade and De-install act on it.
require_installation() {
  if [ ! -f "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then finish 6 "Oracle OPS is not installed on this host"; fi
  describe_installation
  [ -n "$INST_HOME" ] || finish 1 "the installed $UNIT_NAME does not name a usable installation directory"
  if [ -L "$INST_HOME" ] || [ ! -d "$INST_HOME/releases" ]; then
    finish 6 "the Oracle OPS service definition points to $INST_HOME, which is not an Oracle OPS installation directory"
  fi
  valid_account_name "$INST_USER" && valid_account_name "$INST_GROUP" || finish 1 "the installed $UNIT_NAME does not name a usable service account"
}

home_state() {  # new | partial | foreign | symlink
  local h="$1" e found="" stray=""
  if [ -L "$h" ]; then echo symlink; return 0; fi
  if [ ! -e "$h" ]; then echo new; return 0; fi
  if [ ! -d "$h" ]; then echo foreign; return 0; fi
  while IFS= read -r e; do
    case "$e" in releases|config|logs|evidence|runtime|current) found=1 ;; *) stray=1 ;; esac
  done < <(find "$h" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
  if [ -n "$stray" ]; then echo foreign; elif [ -n "$found" ]; then echo partial; else echo new; fi
}

ask_home() {
  local h attempt
  for attempt in 1 2 3; do
    printf '      Installation directory [%s]: ' "$DEFAULT_HOME"
    read_line h || { echo; finish 5 "no installation directory was entered"; }
    h="${h:-$DEFAULT_HOME}"
    [ "$h" = "/" ] || h="${h%/}"
    if valid_home "$h"; then TARGET_HOME="$h"; log "installation directory: $h"; return 0; fi
    say "      Not usable: use an absolute path of letters, digits, '.', '_', '-' and '/', outside system directories."
  done
  finish 2 "no usable installation directory after three attempts"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Verification after an action (read-only; the Oracle OPS scripts have already run their own checks)
# ---------------------------------------------------------------------------------------------------------------------------

# verify_installed <home>: the unit points to <home>, `current` selects the pinned version, the deployed build carries the
# pinned commit, and the service is active.
verify_installed() {
  local h="$1" problems="" rel c v
  if [ ! -f "$UNIT_FILE" ] || [ "$(unit_home)" != "$h" ]; then problems="$problems; the service definition does not point to $h"; fi
  rel="$(current_release "$h")"
  [ "$rel" = "$OPS_VERSION" ] || problems="$problems; the active release is '${rel:-none}', expected $OPS_VERSION"
  v="$(head -n 1 "$h/releases/$OPS_VERSION/VERSION" 2>/dev/null)" || v=""
  [ "$v" = "$OPS_VERSION" ] || problems="$problems; releases/$OPS_VERSION/VERSION is '${v:-missing}'"
  c="$(jar_commit "$h" "$OPS_VERSION")"
  commit_matches_pin "$c" || problems="$problems; the deployed build is from commit '${c:-unknown}', expected ${OPS_COMMIT:0:7}"
  service_active || problems="$problems; $UNIT_NAME is not active"
  if [ -n "$problems" ]; then log "verification FAILED: ${problems#; }"; VERIFY_PROBLEMS="${problems#; }"; return 1; fi
  log "verification passed: home=$h release=$rel commit=$c active=yes"
}
VERIFY_PROBLEMS=""

log_size() { stat -c %s "$1/$SERVICE_LOG_REL" 2>/dev/null || echo 0; }

# db_healthy_since <home> <byte offset>: the service logged a HEALTHY database check after the offset (a rotated log —
# smaller than the offset — is read from its start).
db_healthy_since() {
  local f="$1/$SERVICE_LOG_REL" off="$2" size
  [ -f "$f" ] || return 1
  size="$(stat -c %s "$f")"
  [ "$size" -ge "$off" ] || off=0
  tail -c +"$((off + 1))" "$f" | grep -qF "$DB_HEALTHY_LINE"
}
