#!/bin/bash
# Oracle OPS Installer library: action: status (read-only)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# READ-ONLY by construction (tests/installer-test.sh: the static guard, the boundary snapshots and the mutation tests):
# no network, no database, no Oracle OPS script, nothing sourced, no java. Configuration and credential files are examined by
# metadata (stat) only and never opened. The only systemctl verbs are is-active and show (seam service_state).
# Everything the status of an installation consists of is an "item": a function that sets ITEM_STATUS (OK|WARN|FAIL) and
# ITEM_DETAIL through item_finish; run_item prints and logs it and counts it. An item that cannot be determined is a FAIL.

ITEM_STATUS=""
ITEM_DETAIL=""
ITEM_FAILS=""
ITEM_WARNS=""
ITEM_EXTRA=""
ITEM_NOTE=""
CHECK_COUNT_OK=0
CHECK_COUNT_WARN=0
CHECK_COUNT_FAIL=0
CHECK_NOT_INSTALLED=0
CHECK_KIND=""
STATUS_UNIT_PRESENT=0
STATUS_UNIT_USER=""
STATUS_UNIT_GROUP=""
STATUS_UNIT_HOME=""
STATUS_HOME=""
STATUS_HOME_MISMATCH=""
STATUS_USER=""
STATUS_GROUP=""
STATUS_RELEASE=""
META_ABSENT=0
META_TEXT=""

# ---------------------------------------------------------------------------------------------------------------------------
# Output and the item runner
# ---------------------------------------------------------------------------------------------------------------------------

# check_out <text>: one line on the terminal and in the log, both sanitised (no control sequences, no secrets).
check_out() {
  printf '%s\n' "$*" | sanitize_stream
  log "$*"
}

item_fail() { ITEM_FAILS="${ITEM_FAILS:+$ITEM_FAILS; }$1"; }
item_warn() { ITEM_WARNS="${ITEM_WARNS:+$ITEM_WARNS; }$1"; }

# item_finish <text for OK>: FAIL if any problem was noted, else WARN if any warning, else OK with the text.
item_finish() {
  if [ -n "$ITEM_FAILS" ]; then
    ITEM_STATUS=FAIL; ITEM_DETAIL="$ITEM_FAILS${ITEM_WARNS:+; $ITEM_WARNS}"
  elif [ -n "$ITEM_WARNS" ]; then
    ITEM_STATUS=WARN; ITEM_DETAIL="$ITEM_WARNS"
  else
    ITEM_STATUS=OK; ITEM_DETAIL="$1"
  fi
  if [ -n "$ITEM_NOTE" ]; then ITEM_DETAIL="$ITEM_DETAIL; $ITEM_NOTE"; fi
  return 0
}

# item_need <tool...>: notes a problem for every tool that is missing; false if any is.
item_need() {
  local t rc=0
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then item_fail "the required tool $t is missing"; rc=1; fi
  done
  return "$rc"
}

# run_item <name> <function> [arguments]: runs one item, then prints and logs "<STATUS>  <name>: <detail>" and counts it.
run_item() {
  local name="$1" fn="$2" line
  shift 2
  ITEM_STATUS=""; ITEM_DETAIL=""; ITEM_FAILS=""; ITEM_WARNS=""; ITEM_EXTRA=""; ITEM_NOTE=""
  "$fn" "$@"
  case "$ITEM_STATUS" in OK|WARN|FAIL) ;; *) ITEM_STATUS=FAIL; ITEM_DETAIL="the check ended without a result" ;; esac
  case "$ITEM_STATUS" in
    OK) CHECK_COUNT_OK=$((CHECK_COUNT_OK + 1)) ;;
    WARN) CHECK_COUNT_WARN=$((CHECK_COUNT_WARN + 1)) ;;
    FAIL) CHECK_COUNT_FAIL=$((CHECK_COUNT_FAIL + 1)) ;;
  esac
  check_out "$ITEM_STATUS  $name: $ITEM_DETAIL"
  if [ -n "$ITEM_EXTRA" ]; then
    while IFS= read -r line; do check_out "      | $line"; done <<< "$ITEM_EXTRA"
  fi
}

check_summary() {
  check_out "$1: OK $CHECK_COUNT_OK, WARN $CHECK_COUNT_WARN, FAIL $CHECK_COUNT_FAIL"
  CHECK_SUMMARY_DONE=1
}

# ---------------------------------------------------------------------------------------------------------------------------
# Discovery (from the installed unit; --home must agree with it)
# ---------------------------------------------------------------------------------------------------------------------------

# status_discover: reads User, Group and ORACLE_OPS_HOME from the unit (only if it is a regular file) and decides which
# installation directory the items examine. CHECK_NOT_INSTALLED=1 when there is no unit and no --home.
status_discover() {
  STATUS_UNIT_PRESENT=0; STATUS_UNIT_USER=""; STATUS_UNIT_GROUP=""; STATUS_UNIT_HOME=""
  STATUS_HOME=""; STATUS_HOME_MISMATCH=""; STATUS_USER=""; STATUS_GROUP=""; STATUS_RELEASE=""; CHECK_NOT_INSTALLED=0
  if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then STATUS_UNIT_PRESENT=1; fi
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then
    STATUS_UNIT_USER="$(unit_value User)"
    STATUS_UNIT_GROUP="$(unit_value Group)"
    STATUS_UNIT_HOME="$(unit_home)"
  fi
  if [ "$STATUS_UNIT_PRESENT" = 0 ] && [ "$CLI_HOME_SET" = 0 ]; then CHECK_NOT_INSTALLED=1; return 0; fi
  if valid_home "$STATUS_UNIT_HOME"; then
    STATUS_HOME="$STATUS_UNIT_HOME"
    if [ "$CLI_HOME_SET" = 1 ] && [ "$CLI_HOME" != "$STATUS_UNIT_HOME" ]; then
      STATUS_HOME_MISMATCH="--home $CLI_HOME does not match the installation directory the unit names ($STATUS_UNIT_HOME)"
    fi
  elif [ "$CLI_HOME_SET" = 1 ]; then
    STATUS_HOME="$CLI_HOME"
  fi
  if valid_account_name "$STATUS_UNIT_USER"; then STATUS_USER="$STATUS_UNIT_USER"; fi
  if valid_account_name "$STATUS_UNIT_GROUP"; then STATUS_GROUP="$STATUS_UNIT_GROUP"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------------------
# Metadata helper: never opens the file
# ---------------------------------------------------------------------------------------------------------------------------

# status_meta_check <label> <path> <f|d> <admin|service> <mode>: examines <path> with stat only. A missing path sets
# META_ABSENT=1 and notes nothing; any deviation (link, other type, owner, group, mode, hard links) is noted as a problem.
# <admin> = owned by the administrative account (root), <service> = owned by the unit's User; the group is the unit's Group.
status_meta_check() {
  local label="$1" p="$2" want="$3" ownkind="$4" wantmode="$5" st type uid user grp mode links kind
  META_ABSENT=0; META_TEXT=""
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then META_ABSENT=1; return 0; fi
  if ! st="$(stat -c '%F|%u|%U|%G|%a|%h' -- "$p" 2>/dev/null)"; then item_fail "$label: cannot be examined"; return 0; fi
  IFS='|' read -r type uid user grp mode links <<< "$st"
  case "$type" in
    "regular file"|"regular empty file") kind=f ;;
    directory) kind=d ;;
    "symbolic link") kind=l ;;
    *) kind=o ;;
  esac
  META_TEXT="$type $user:$grp $mode"
  if [ "$kind" = l ]; then item_fail "$label: $p is a symbolic link"; return 0; fi
  if [ "$kind" != "$want" ]; then item_fail "$label: $p is not a $([ "$want" = f ] && echo regular file || echo directory) ($type)"; return 0; fi
  if [ "$ownkind" = admin ]; then
    [ "$uid" = "$ADMIN_UID" ] || item_fail "$label: owner is $user (uid $uid), expected the administrative account (uid $ADMIN_UID)"
  elif [ -z "$STATUS_USER" ]; then
    item_fail "$label: the service user cannot be determined from the unit"
  elif [ "$user" != "$STATUS_USER" ]; then
    item_fail "$label: owner is $user, expected the service user $STATUS_USER"
  fi
  if [ -z "$STATUS_GROUP" ]; then
    item_fail "$label: the service group cannot be determined from the unit"
  elif [ "$grp" != "$STATUS_GROUP" ]; then
    item_fail "$label: group is $grp, expected the service group $STATUS_GROUP"
  fi
  [ "$mode" = "$wantmode" ] || item_fail "$label: mode is $mode, expected $wantmode"
  if [ "$want" = f ] && [ "$links" != 1 ]; then item_fail "$label: $links hard links, expected 1"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------------------
# The items
# ---------------------------------------------------------------------------------------------------------------------------

# 1: the systemd unit
status_item_unit() {
  local st own mode
  if [ ! -e "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then item_fail "$UNIT_FILE does not exist"; item_finish ""; return 0; fi
  if [ -L "$UNIT_FILE" ]; then item_fail "$UNIT_FILE is a symbolic link"; item_finish ""; return 0; fi
  if [ ! -f "$UNIT_FILE" ]; then item_fail "$UNIT_FILE is not a regular file"; item_finish ""; return 0; fi
  if ! st="$(stat -c '%u %a' -- "$UNIT_FILE" 2>/dev/null)"; then item_fail "$UNIT_FILE cannot be examined"; item_finish ""; return 0; fi
  own="${st%% *}"; mode="${st##* }"
  [ "$own" = "$ADMIN_UID" ] || item_fail "$UNIT_FILE is not owned by the administrative account (owner uid $own)"
  [ $((8#$mode & 8#022)) -eq 0 ] || item_fail "$UNIT_FILE is writable by group or other users (mode $mode)"
  [ -n "$STATUS_USER" ] || item_fail "the unit has no usable User= ('$STATUS_UNIT_USER')"
  [ -n "$STATUS_GROUP" ] || item_fail "the unit has no usable Group= ('$STATUS_UNIT_GROUP')"
  valid_home "$STATUS_UNIT_HOME" || item_fail "the unit has no usable Environment=ORACLE_OPS_HOME= ('$STATUS_UNIT_HOME')"
  item_finish "$UNIT_FILE: regular file, root-owned, mode $mode; User=$STATUS_USER Group=$STATUS_GROUP ORACLE_OPS_HOME=$STATUS_UNIT_HOME"
  return 0
}

# 2: the installation directory
status_item_home() {
  if [ -z "$STATUS_HOME" ]; then
    item_fail "no installation directory can be determined (the unit names no usable one and no --home was given)"
    item_finish ""; return 0
  fi
  [ -z "$STATUS_HOME_MISMATCH" ] || item_fail "$STATUS_HOME_MISMATCH"
  if [ -L "$STATUS_HOME" ]; then
    item_fail "$STATUS_HOME is a symbolic link"
  elif [ ! -d "$STATUS_HOME" ]; then
    item_fail "$STATUS_HOME is not a directory"
  elif [ -L "$STATUS_HOME/releases" ] || [ ! -d "$STATUS_HOME/releases" ]; then
    item_fail "$STATUS_HOME has no releases/ directory"
  fi
  item_finish "$STATUS_HOME: real directory with releases/"
  return 0
}

# 3: the release `current` selects
status_item_current() {
  local rel="" d v=""
  if [ -z "$STATUS_HOME" ]; then item_fail "no installation directory"; item_finish ""; return 0; fi
  if [ ! -L "$STATUS_HOME/current" ]; then
    item_fail "$STATUS_HOME/current is not a symbolic link to a release"
    item_finish ""; return 0
  fi
  if rel="$(current_release "$STATUS_HOME")"; then :; else rel=""; fi
  if [ -z "$rel" ]; then item_fail "current does not select a release under releases/"; item_finish ""; return 0; fi
  STATUS_RELEASE="$rel"
  d="$STATUS_HOME/releases/$rel"
  if [ -L "$d" ] || [ ! -d "$d" ]; then item_fail "releases/$rel is not a real directory"; item_finish ""; return 0; fi
  if [ -f "$d/VERSION" ] && [ ! -L "$d/VERSION" ]; then
    if v="$(head -n 1 "$d/VERSION" 2>/dev/null)"; then :; else v=""; fi
  fi
  [ "$v" = "$rel" ] || item_fail "releases/$rel/VERSION is '${v:-missing}', expected $rel"
  if [ "$rel" != "$OPS_VERSION" ]; then item_warn "the current release is $rel; this installer pins Oracle OPS $OPS_VERSION"; fi
  item_finish "current selects releases/$rel (VERSION $v)"
  return 0
}

# 4: the build commit of the current release against the pin
status_item_commit() {
  local c=""
  item_need unzip || { item_finish ""; return 0; }
  if [ -z "$STATUS_RELEASE" ]; then item_fail "there is no current release to examine"; item_finish ""; return 0; fi
  if c="$(jar_commit "$STATUS_HOME" "$STATUS_RELEASE")"; then :; else c=""; fi
  if [ -z "$c" ]; then
    item_fail "the build commit of release $STATUS_RELEASE cannot be read (releases/$STATUS_RELEASE/oracle-ops.jar missing or without build.gitCommit)"
  elif commit_matches_pin "$c"; then
    :
  else
    item_warn "the build commit $c differs from the pinned commit ${OPS_COMMIT:0:7}"
  fi
  item_finish "build commit $c matches the pinned commit ${OPS_COMMIT:0:7}"
  return 0
}

# 5: the other installed releases (information)
status_item_releases() {
  local names name c list=""
  if [ -z "$STATUS_HOME" ] || [ ! -d "$STATUS_HOME/releases" ]; then item_fail "there is no releases/ directory"; item_finish ""; return 0; fi
  if ! names="$(find "$STATUS_HOME/releases" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)"; then
    item_fail "releases/ cannot be listed"; item_finish ""; return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" != "$STATUS_RELEASE" ] || continue
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then list="${list:+$list, }(unusual entry name)"; continue; fi
    c=""
    if [ -d "$STATUS_HOME/releases/$name" ] && [ ! -L "$STATUS_HOME/releases/$name" ] && command -v unzip >/dev/null 2>&1; then
      if c="$(jar_commit "$STATUS_HOME" "$name")"; then :; else c=""; fi
    fi
    list="${list:+$list, }$name (commit ${c:-unknown})"
  done <<< "$(LC_ALL=C sort <<< "$names")"
  item_finish "${list:-no other release installed}"
  return 0
}

# 6: the Java runtime the release requires is the one runtime/java/current selects (nothing is executed)
status_item_runtime() {
  local props want="" cur t base sel=""
  if [ -z "$STATUS_HOME" ] || [ -z "$STATUS_RELEASE" ]; then item_fail "there is no current release to examine"; item_finish ""; return 0; fi
  item_need readlink || { item_finish ""; return 0; }
  props="$STATUS_HOME/releases/$STATUS_RELEASE/runtime.properties"
  if [ -f "$props" ] && [ ! -L "$props" ]; then
    if want="$(sed -n 's/^jdk\.version=//p' "$props" | head -n 1 | tr -d '\r')"; then :; else want=""; fi
  fi
  [ -n "$want" ] || item_fail "releases/$STATUS_RELEASE/runtime.properties has no jdk.version"
  cur="$STATUS_HOME/runtime/java/current"
  if [ ! -L "$cur" ]; then
    item_fail "runtime/java/current is not a symbolic link"
  else
    if t="$(readlink -f "$cur" 2>/dev/null)" && base="$(readlink -f "$STATUS_HOME" 2>/dev/null)/runtime/java/"; then
      case "$t" in "$base"?*) sel="${t#"$base"}" ;; esac
    fi
    if [ -z "$sel" ] || [ "${sel#*/}" != "$sel" ]; then
      item_fail "runtime/java/current does not select a runtime directory under runtime/java/"
    elif [ ! -d "$t" ]; then
      item_fail "runtime/java/current selects $sel, which is not a directory"
    elif [ -n "$want" ] && [ "$sel" != "$want" ]; then
      item_fail "release $STATUS_RELEASE requires JDK $want but runtime/java/current selects $sel"
    fi
  fi
  item_finish "JDK $want required by release $STATUS_RELEASE is the one runtime/java/current selects"
  return 0
}

# 7: the service, through the seams service_state and proc_owner_exe
status_item_service() {
  local out is="" active="" sub="" pid="" since="" line po own="" exe="" realhome=""
  item_need systemctl || { item_finish ""; return 0; }
  if ! out="$(service_state)"; then
    item_fail "systemctl show failed: the state of $UNIT_NAME cannot be determined"; item_finish ""; return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      IS_ACTIVE=*) is="${line#IS_ACTIVE=}" ;;
      ActiveState=*) active="${line#ActiveState=}" ;;
      SubState=*) sub="${line#SubState=}" ;;
      MainPID=*) pid="${line#MainPID=}" ;;
      ActiveEnterTimestamp=*) since="${line#ActiveEnterTimestamp=}" ;;
    esac
  done <<< "$out"
  if [ -z "$is" ] || [ -z "$active" ] || [ -z "$sub" ]; then
    item_fail "the state of $UNIT_NAME cannot be determined (is-active '${is}', ActiveState '${active}', SubState '${sub}')"
    item_finish ""; return 0
  fi
  if [ "$is" != active ] || [ "$active" != active ] || [ "$sub" != running ]; then
    item_fail "$UNIT_NAME is not running (is-active: $is, ActiveState: $active, SubState: $sub)"
    item_finish ""; return 0
  fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 0 ]; then item_fail "$UNIT_NAME is active but has no main process (MainPID '$pid')"; item_finish ""; return 0; fi
  if ! po="$(proc_owner_exe "$pid")"; then
    item_fail "the owner and program of process $pid cannot be read from /proc"; item_finish ""; return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      OWNER=*) own="${line#OWNER=}" ;;
      EXE=*) exe="${line#EXE=}" ;;
    esac
  done <<< "$po"
  if [ -z "$STATUS_USER" ] || [ -z "$STATUS_GROUP" ]; then
    item_fail "the service account cannot be determined from the unit, so the process owner cannot be checked"
  elif [ "$own" != "$STATUS_USER:$STATUS_GROUP" ]; then
    item_fail "process $pid runs as ${own:-unknown}, expected $STATUS_USER:$STATUS_GROUP"
  fi
  if [ -z "$STATUS_HOME" ]; then
    item_fail "no installation directory, so the program of process $pid cannot be checked"
  elif ! realhome="$(readlink -f "$STATUS_HOME" 2>/dev/null)"; then
    item_fail "$STATUS_HOME cannot be resolved"
  else
    case "$exe" in
      "$realhome/runtime/java/"?*) ;;
      *) item_fail "process $pid runs ${exe:-an unknown program}, not a program under $realhome/runtime/java/" ;;
    esac
  fi
  item_finish "active (running) since ${since:-unknown}; MainPID $pid runs as $own; program $exe"
  return 0
}

# 8: the service log (last STATUS_LOG_TAIL lines): the lifecycle and database health lines, reported verbatim
status_item_service_log() {
  local f t run health state
  item_need tail grep || { item_finish ""; return 0; }
  if [ -z "$STATUS_HOME" ]; then item_fail "no installation directory"; item_finish ""; return 0; fi
  f="$STATUS_HOME/$SERVICE_LOG_REL"
  if [ -L "$f" ] || [ ! -f "$f" ]; then item_fail "$f is missing or not a regular file"; item_finish ""; return 0; fi
  if ! t="$(tail -n "$STATUS_LOG_TAIL" -- "$f" 2>/dev/null)"; then item_fail "$f cannot be read"; item_finish ""; return 0; fi
  if run="$(printf '%s\n' "$t" | grep -F 'is RUNNING' | tail -n 1 | cut -c1-240)"; then :; else run=""; fi
  if health="$(printf '%s\n' "$t" | grep -F 'Database connectivity startup health check:' | tail -n 1 | cut -c1-240)"; then :; else health=""; fi
  if state="$(printf '%s\n' "$t" | grep -F -e 'Starting Oracle OPS' -e 'is RUNNING' -e 'is STOPPING' -e 'is STOPPED' | tail -n 1 | cut -c1-240)"; then :; else state=""; fi
  [ -n "$run" ] || item_warn "no 'is RUNNING' line in the last $STATUS_LOG_TAIL lines of the service log"
  if [ -z "$health" ]; then
    item_warn "no database health line in the last $STATUS_LOG_TAIL lines of the service log"
  else
    case "$health" in *"check: HEALTHY"*) ;; *) item_warn "the latest database health line is not HEALTHY" ;; esac
  fi
  if [ -z "$state" ]; then
    item_warn "no start or stop line in the last $STATUS_LOG_TAIL lines of the service log"
  else
    case "$state" in *"is RUNNING"*) ;; *) item_warn "the latest start/stop line is not 'is RUNNING'" ;; esac
  fi
  item_finish "latest state: ${state:-none} | latest RUNNING: ${run:-none} | latest database health: ${health:-none}"
  return 0
}

# 9: configuration/application.yaml (metadata only)
status_item_configuration() {
  local p
  if [ -z "$STATUS_HOME" ]; then item_fail "no installation directory"; item_finish ""; return 0; fi
  p="$STATUS_HOME/config/application.yaml"
  status_meta_check "application.yaml" "$p" f admin 640
  [ "$META_ABSENT" = 0 ] || item_fail "$p does not exist"
  item_finish "$p: $META_TEXT (metadata only; the file is not opened)"
  return 0
}

# 10: the credential directory (metadata only)
status_item_credential_dir() {
  status_meta_check "credential directory" "$CRED_DIR" d admin 750
  [ "$META_ABSENT" = 0 ] || item_fail "$CRED_DIR does not exist"
  item_finish "$CRED_DIR: $META_TEXT"
  return 0
}

# 11: the credential files (metadata only; never opened). Absent files are fine: not every feature has one.
status_item_credential_files() {
  local spec name kind mode present="" absent="" p
  for spec in $CRED_FILES; do
    name="${spec%%:*}"; mode="${spec##*:}"; kind="${spec#*:}"; kind="${kind%%:*}"
    p="$CRED_DIR/$name"
    if [ "$kind" = service ]; then
      status_meta_check "$name" "$p" f service "$mode"
    else
      status_meta_check "$name" "$p" f admin "$mode"
    fi
    if [ "$META_ABSENT" = 1 ]; then absent="${absent:+$absent, }$name"; else present="${present:+$present, }$name ($META_TEXT)"; fi
  done
  item_finish "present: ${present:-none}; not present: ${absent:-none} (metadata only; no file is opened)"
  return 0
}

# 12: the installer's own state: warnings of the strict start-up, leftovers of interrupted runs (reported, never removed)
status_item_installer_state() {
  local e d pid notes live="" dead="" other="" base
  [ -z "$CHECK_DIR_NOTES" ] || item_warn "$CHECK_DIR_NOTES"
  base=""
  [ -z "$RUN_DIR" ] || base="${RUN_DIR##*/}"
  if [ -d "$STATE_DIR" ] && notes="$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)"; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      case "$e" in .lock) continue ;; esac
      [ "$e" != "$base" ] || continue
      d="$STATE_DIR/$e"
      case "$e" in
        run.*)
          if [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/$MARKER_NAME" ]; then
            pid="$(head -n 1 "$d/$MARKER_NAME" 2>/dev/null | cut -d' ' -f2)"
            if [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; then live="${live:+$live, }$e (pid $pid)"; else dead="${dead:+$dead, }$e"; fi
          else
            other="${other:+$other, }$e"
          fi ;;
        *) other="${other:+$other, }$e" ;;
      esac
    done <<< "$notes"
  fi
  if [ -d "$AUTH_BASE" ] && notes="$(find "$AUTH_BASE" -mindepth 1 -maxdepth 1 -name 'oracle-ops-installer.*' -printf '%f\n' 2>/dev/null)"; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      d="$AUTH_BASE/$e"
      if [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/$MARKER_NAME" ]; then
        pid="$(head -n 1 "$d/$MARKER_NAME" 2>/dev/null | cut -d' ' -f2)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ]; then live="${live:+$live, }$AUTH_BASE/$e (pid $pid)"; else dead="${dead:+$dead, }$AUTH_BASE/$e (token directory)"; fi
      else
        other="${other:+$other, }$AUTH_BASE/$e"
      fi
    done <<< "$notes"
  fi
  [ -z "$dead" ] || item_warn "leftover of an interrupted run, its process is gone: $dead (not removed; the menu start-up removes it at its next run)"
  [ -z "$other" ] || item_warn "unexpected entry not created by this installer: $other (not removed)"
  [ -z "$live" ] || ITEM_NOTE="in use by a running installer: $live"
  item_finish "no leftover of an interrupted run"
  return 0
}

# 13: a statement: no Oracle OPS check and no database access in this item set
status_item_no_ops_check() {
  ITEM_STATUS=OK
  if [ "$CHECK_KIND" = validate ]; then
    ITEM_DETAIL="no database access and no Oracle OPS program was started by the items above"
  else
    ITEM_DETAIL="no Oracle OPS script, no java and no database access was used; 'validate' runs the pinned release's own checks"
  fi
  return 0
}

# status_items: the items 1 to 13.
status_items() {
  run_item unit status_item_unit
  run_item home status_item_home
  run_item current-release status_item_current
  run_item build-commit status_item_commit
  run_item other-releases status_item_releases
  run_item runtime status_item_runtime
  run_item service status_item_service
  run_item service-log status_item_service_log
  run_item configuration status_item_configuration
  run_item credential-directory status_item_credential_dir
  run_item credential-files status_item_credential_files
  run_item installer-state status_item_installer_state
  run_item ops-check status_item_no_ops_check
}

# status_run: the whole status (after status_discover found an installation).
status_run() {
  CHECK_KIND=status
  check_out "Oracle OPS status (installer $INSTALLER_VERSION; pinned Oracle OPS $OPS_VERSION, commit ${OPS_COMMIT:0:7})"
  status_items
  check_summary "status"
  if [ "$CHECK_COUNT_FAIL" -gt 0 ]; then CHECK_RC=1; else CHECK_RC=0; fi
  return 0
}

# op_status: menu choice 5, after the normal start-up (the installer log, the exclusive lock and run directory exist).
op_status() {
  OPERATION="status check"
  status_discover
  [ "$CHECK_NOT_INSTALLED" = 0 ] || finish 6 "Oracle OPS is not installed on this host"
  status_run
  [ "$CHECK_RC" = 0 ] || finish "$CHECK_RC" "the status check found $CHECK_COUNT_FAIL problem(s)"
  finish 0
}
