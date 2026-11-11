#!/bin/bash
# Oracle OPS Installer library: action: Fresh Installation (0.3.0)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# Flow (README "Fresh Installation"):
#   1 system check (read-only: prerequisites, existing installation, discovery report)
#   2 settings: installation directory, service account, repository database (host, port, service; the listener is probed),
#     REST API listener (bind address, APEX/ORDS client addresses when it is not loopback, port) - nothing is changed
#   3 review screen, typed "yes" - nothing is changed before it
#   4 database prerequisites: the DBA SQL (tablespace, OPS_OWNER, OPS_RUNTIME) is written and shown, or the DBA did it already
#   5 download of the pinned release (GitHub access token, removed before any downloaded code runs)
#   6 the private JDK (Oracle OPS's provision-java.sh), then the Oracle OPS tables and packages, created as OPS_OWNER
#     (lib/db-deploy.sh, lib/db-tool.sh)
#   7 both REST API keys created in /etc/oracle-ops (an existing valid key file is kept)
#   8 Oracle OPS's own setup assistant (deploy-oracle-ops.sh) with every answer above passed as options: it asks the
#     OPS_RUNTIME password, proves that login, stores it in /etc/oracle-ops/database.credentials, asks ops.node and the
#     optional EBS settings, shows its own summary and "yes", deploys, starts and checks. It accepts only a loopback
#     listener, so a network bind address is applied afterwards (application.yaml backed up, validated by Oracle OPS's
#     config-migrate.sh, restarted, checked; restored on failure)
#   9 final validation, then both API keys are shown with the APEX Web Credential settings and the screen is cleared

# ---------------------------------------------------------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------------------------------------------------------

# primary_group_of <user>: the name of the user's primary group, from the account database; empty if unknown.
primary_group_of() {
  local gid
  gid="$({ getent passwd "$1" 2>/dev/null || true; } | cut -d: -f4)"
  [[ "$gid" =~ ^[0-9]+$ ]] || return 0
  { getent group "$gid" 2>/dev/null || true; } | cut -d: -f1
}

ask_service_account() {
  local u g uid gid def attempt
  say "      Oracle OPS runs as an existing operating-system account. It is never created or changed, and never root."
  for attempt in 1 2 3; do
    printf '      Service account user: '
    read_line u || { echo; finish 5 "no service account was entered"; }
    if ! valid_account_name "$u"; then say "      Not a valid account name."; continue; fi
    uid="$(account_uid "$u")"
    if [[ ! "$uid" =~ ^[0-9]+$ ]]; then say "      There is no account '$u' on this host. Create it first (your account management), or enter another."; continue; fi
    if [ "$uid" = 0 ]; then say "      root is not allowed: Oracle OPS never runs as root."; continue; fi
    SVC_USER="$u"; break
  done
  [ -n "$SVC_USER" ] || finish 2 "no usable service account after three attempts"
  def="$(primary_group_of "$SVC_USER")"
  for attempt in 1 2 3; do
    printf '      Service account group [%s]: ' "${def:-none}"
    read_line g || { echo; finish 5 "no service group was entered"; }
    g="${g:-$def}"
    if [ -z "$g" ] || ! valid_account_name "$g"; then say "      Not a valid group name."; continue; fi
    gid="$(group_gid "$g")"
    if [[ ! "$gid" =~ ^[0-9]+$ ]]; then say "      There is no group '$g' on this host."; continue; fi
    if [ "$gid" = 0 ]; then say "      The root group is not allowed."; continue; fi
    SVC_GROUP="$g"; SVC_GID="$gid"; break
  done
  [ -n "$SVC_GROUP" ] || finish 2 "no usable service group after three attempts"
  log "service account: $SVC_USER:$SVC_GROUP (gid $SVC_GID)"
}

valid_loopback() {
  local a="$1" o
  [ "$a" = "::1" ] && return 0
  [[ "$a" =~ ^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  for o in ${a//./ }; do [ "$((10#$o))" -le 255 ] || return 1; done
}

valid_ip() {   # an IPv4 or IPv6 literal, never a wildcard
  local a="$1" o
  case "$a" in 0.0.0.0|::|0:0:0:0:0:0:0:0) return 1 ;; esac
  if [[ "$a" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    for o in ${a//./ }; do [ "$((10#$o))" -le 255 ] || return 1; done
    return 0
  fi
  [[ "$a" =~ ^[0-9A-Fa-f:]{2,39}$ ]] && [[ "$a" == *:* ]]
}

is_local_address() { local_addresses | grep -qxF -- "$1"; }

ask_db_target() {
  local h p s attempt re='^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
  say "      The Oracle OPS repository database (the PDB that holds, or will hold, $DB_OWNER and $DB_RUNTIME):"
  for attempt in 1 2 3; do
    DB_HOST=""; DB_PORT=""
    printf '      Database host (name or IPv4 address): '
    read_line h || { echo; finish 5 "no database host was entered"; }
    if [[ ! "$h" =~ $re ]] || [[ "$h" == *..* ]]; then say "      Enter a host name or an IPv4 address."; continue; fi
    printf '      Database listener port [%s]: ' "$DEFAULT_DB_PORT"
    read_line p || { echo; finish 5 "no port was entered"; }
    p="${p:-$DEFAULT_DB_PORT}"
    if [[ ! "$p" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$p))" -lt 1 ] || [ "$((10#$p))" -gt 65535 ]; then say "      Enter a port from 1 to 65535."; continue; fi
    p="$((10#$p))"
    if ! tcp_open "$h" "$p"; then say "      No database listener answers at $h:$p from this host (check the name, the port and the firewall)."; continue; fi
    DB_HOST="$h"; DB_PORT="$p"; break
  done
  [ -n "$DB_HOST" ] || finish 2 "no reachable database listener after three attempts"
  for attempt in 1 2 3; do
    printf '      Database service name (of the PDB, not a SID): '
    read_line s || { echo; finish 5 "no service name was entered"; }
    if [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then DB_SERVICE="$s"; break; fi
    say "      Enter a service name (letters, digits, '_', '.', '-'; at most 64 characters)."
  done
  [ -n "$DB_SERVICE" ] || finish 2 "no usable service name after three attempts"
  log "repository database: $DB_HOST:$DB_PORT/$DB_SERVICE (listener reachable)"
}

ask_api_listener() {
  local b p c a attempt ok others
  others="$(local_addresses | grep -v -E '^(127\.|::1$)' | tr '\n' ' ')"
  say "      The REST API (GET and POST) is installed and enabled, over plain HTTP (HTTPS comes later)."
  say "      Bind address: 127.0.0.1 when Oracle APEX/ORDS runs on this host; otherwise this host's address that the"
  say "      APEX/ORDS server reaches${others:+ (this host has: $others)}."
  for attempt in 1 2 3; do
    printf '      REST API bind address [%s]: ' "$DEFAULT_API_BIND"
    read_line b || { echo; finish 5 "no bind address was entered"; }
    b="${b:-$DEFAULT_API_BIND}"
    if valid_loopback "$b"; then API_BIND="$b"; break; fi
    if ! valid_ip "$b"; then say "      Enter an IP address of this host (not a name, not 0.0.0.0)."; continue; fi
    if ! is_local_address "$b"; then say "      $b is not an address of this host."; continue; fi
    API_BIND="$b"; break
  done
  [ -n "$API_BIND" ] || finish 2 "no usable bind address after three attempts"
  if ! valid_loopback "$API_BIND"; then
    say "      Only the APEX/ORDS server(s) you name here may call the API (Oracle OPS refuses every other caller)."
    say "      Note: with Oracle OPS $OPS_VERSION a caller on another host gets About and Status; the other APIs answer on"
    say "      this host only until a later Oracle OPS release opens them."
    for attempt in 1 2 3; do
      printf '      IP address(es) of the APEX/ORDS server, comma-separated (at most %s): ' "$API_CLIENTS_MAX"
      read_line c || { echo; finish 5 "no client address was entered"; }
      c="${c// /}"; ok=1
      [ -n "$c" ] || ok=0
      [ "$(printf '%s' "$c" | tr ',' '\n' | grep -c .)" -le "$API_CLIENTS_MAX" ] || ok=0
      for a in ${c//,/ }; do valid_ip "$a" || ok=0; done
      if [ "$ok" = 1 ]; then API_CLIENTS="$c"; break; fi
      say "      Enter 1 to $API_CLIENTS_MAX IP addresses separated by commas (no names, no ranges, no 0.0.0.0)."
    done
    [ -n "$API_CLIENTS" ] || finish 2 "no usable APEX/ORDS address after three attempts"
  fi
  for attempt in 1 2 3; do
    printf '      REST API port (%s-65535): ' "$API_PORT_MIN"
    read_line p || { echo; finish 5 "no port was entered"; }
    if [[ ! "$p" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$p))" -lt "$API_PORT_MIN" ] || [ "$((10#$p))" -gt 65535 ]; then
      say "      Enter a number from $API_PORT_MIN to 65535."; continue
    fi
    p="$((10#$p))"
    if port_in_use "$API_BIND" "$p" || port_in_use "$DEFAULT_API_BIND" "$p"; then say "      Port $p is already in use on this host. Choose another."; continue; fi
    API_PORT="$p"; break
  done
  [ -n "$API_PORT" ] || finish 2 "no usable port after three attempts"
  log "REST API listener: $API_BIND:$API_PORT${API_CLIENTS:+ clients $API_CLIENTS}"
}

# key_plan <read|control>: what Fresh Installation will do with one key file.
key_plan() {
  api_key_spec "$1"
  if [ -L "$AK_FILE" ]; then printf 'REFUSED: %s is a symbolic link' "$AK_FILE"
  elif [ -f "$AK_FILE" ]; then
    local _v=""
    if read_api_key "$AK_FILE" "$AK_PROP" _v; then printf 'exists and is valid: kept as it is'
    else printf 'REFUSED: %s is not a valid key file (one %s line of at least %s characters, a single link)' "$AK_FILE" "$AK_PROP" "$API_KEY_MIN_CHARS"; fi
    _v=""
  elif [ -e "$AK_FILE" ]; then printf 'REFUSED: %s is not a regular file' "$AK_FILE"
  else printf 'will be created (64 random hex characters, root:%s 0640)' "$SVC_GROUP"; fi
}

show_install_review() {
  local r c api
  r="$(key_plan read)"; c="$(key_plan control)"
  case "$r$c" in *REFUSED*) say "      Read key: $r"; say "      Control key: $c"; finish 1 "an API key file cannot be used; nothing was changed" ;; esac
  if valid_loopback "$API_BIND"; then api="enabled, plain HTTP on $API_BIND:$API_PORT (callers on this host)"
  else api="enabled, plain HTTP on $API_BIND:$API_PORT, callers allowed: $API_CLIENTS (and this host)"; fi
  echo
  say "      ================================ Review ================================"
  printf '      %-26s %s\n' \
    "Oracle OPS release" "$OPS_VERSION (commit ${OPS_COMMIT:0:7}), downloaded from the private repository" \
    "Installation directory" "$TARGET_HOME" \
    "Service account" "$SVC_USER:$SVC_GROUP (existing; not changed)" \
    "Java" "the release's pinned private JDK, installed under the installation directory" \
    "Database" "$DB_HOST:$DB_PORT/$DB_SERVICE (listener reachable)" \
    "Database schema" "$DB_OWNER (objects), $DB_RUNTIME (service login), tablespace $DB_TABLESPACE - created by the DBA" \
    "Tables and packages" "created by the installer as $DB_OWNER (password asked at that step, never stored)" \
    "Runtime password" "$DB_RUNTIME's password asked by the setup assistant, stored in $CRED_DIR/database.credentials" \
    "REST API" "$api" \
    "Read key (GET APIs)" "$CRED_DIR/api.credentials - $r" \
    "Control key (POST APIs)" "$CRED_DIR/api-control.credentials - $c" \
    "Start/stop (POST)" "off after installation (ebs.control.enabled: false)" \
    "EBS integration" "asked by the Oracle OPS setup assistant (optional)"
  echo
  say "      After you type yes, in this order:"
  say "        1. The DBA SQL for the schema (if the DBA has not run it yet); the installer waits for the DBA."
  say "        2. Download Oracle OPS $OPS_VERSION (GitHub access token asked, removed after the download)."
  say "        3. The private Java runtime under $TARGET_HOME, then the Oracle OPS tables and packages as $DB_OWNER."
  say "        4. The two API key files that are marked 'will be created'."
  say "        5. The Oracle OPS setup assistant: its own checks, summary and confirmation, then the installation."
  valid_loopback "$API_BIND" || say "        6. The REST API is moved from 127.0.0.1 to $API_BIND (configuration backed up first)."
  say "      Never changed: database accounts, tablespaces, OS accounts and groups, parent directories."
  say "      The API keys are shown at the end, for the APEX Web Credentials."
  echo
}

# ---------------------------------------------------------------------------------------------------------------------------
# Final validation
# ---------------------------------------------------------------------------------------------------------------------------

# routes_since <home> <byte offset>: the last "API routes served: [...]" line the service logged after the offset.
routes_since() {
  local f="$1/$SERVICE_LOG_REL" off="$2" size
  [ -f "$f" ] || return 0
  size="$(stat -c %s "$f")"
  [ "$size" -ge "$off" ] || off=0
  { tail -c +"$((off + 1))" "$f" | grep -F -- "$API_ROUTES_LINE" || true; } | tail -n 1
}

FINAL_FAILS=""
final_check() {   # final_check <label> <PASS|FAIL> [detail]
  printf '      [%s] %s%s\n' "$2" "$1" "${3:+ - $3}"
  log "final validation: $2 $1${3:+ - $3}"
  [ "$2" = PASS ] || FINAL_FAILS="${FINAL_FAILS:+$FINAL_FAILS; }$1${3:+ ($3)}"
}

install_final_checks() {   # <home> <log offset before the first start> <log offset before the last start>
  local h="$1" offset="$2" routes_offset="${3:-$2}" line scope
  FINAL_FAILS=""
  if verify_installed "$h"; then final_check "Service, release $OPS_VERSION and build commit ${OPS_COMMIT:0:7}" PASS
  else final_check "Service, release and build commit" FAIL "$VERIFY_PROBLEMS"; fi
  if db_healthy_since "$h" "$offset"; then final_check "Database connection (runtime account)" PASS "$DB_HEALTHY_LINE"
  else final_check "Database connection (runtime account)" FAIL "no \"$DB_HEALTHY_LINE\" in $h/$SERVICE_LOG_REL"; fi
  line="$(routes_since "$h" "$routes_offset")"
  case "$line" in
    *"$API_STATUS_PATH"*) line="${line#*"$API_ROUTES_LINE"}"; final_check "REST API deployed" PASS "routes: ${line%%]*}" ;;
    "") final_check "REST API deployed" FAIL "the service did not report its API routes" ;;
    *) final_check "REST API deployed" FAIL "$API_STATUS_PATH is not among the reported routes" ;;
  esac
  if ! valid_loopback "$API_BIND"; then
    line="$(yaml_api_listener "$h/config/application.yaml")"
    if [ "$line" = "$API_BIND $API_PORT" ] && grep -qF "    client-addresses: \"$API_CLIENTS\"" "$h/config/application.yaml"; then
      final_check "REST API listener" PASS "$API_BIND:$API_PORT for $API_CLIENTS"
    else
      final_check "REST API listener" FAIL "application.yaml does not hold $API_BIND:$API_PORT with the client addresses"
    fi
  fi
  for scope in read control; do
    api_key_spec "$scope"
    if key_meta_ok "$AK_FILE" "$SVC_GID"; then final_check "$(api_key_label "$scope") file" PASS "$AK_FILE root:$SVC_GROUP 0640"
    else final_check "$(api_key_label "$scope") file" FAIL "$AK_FILE is not a single regular file root:$SVC_GROUP 0640"; fi
  done
  if run_quiet "service-identity.sh check" ops_run service-identity.sh check --home "$h"; then
    final_check "Files and process belong to $SVC_USER:$SVC_GROUP" PASS
  else
    final_check "Files and process belong to $SVC_USER:$SVC_GROUP" FAIL "service-identity.sh check reported deviations (see the log)"
  fi
}

# wait_for_routes <home> <offset>: up to RESTART_WAIT_SECONDS for the service to be active and to log its routes after
# <offset>. Prints the route line; false on timeout.
wait_for_routes() {
  local waited=0 line=""
  while [ "$waited" -le "$RESTART_WAIT_SECONDS" ]; do
    line="$(routes_since "$1" "$2")"
    if [ -n "$line" ] && service_active; then printf '%s' "$line"; return 0; fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# set_network_listener: the setup assistant installed the API on 127.0.0.1 (the only listener it accepts); move it to the
# chosen address with the client allowlist (Oracle OPS's api.plain-http.client-addresses). Backup, validate with Oracle OPS's
# own config-migrate.sh, restart, check; on any failure the original configuration is restored and the service restarted.
NETWORK_OFFSET=""
set_network_listener() {
  local h="$TARGET_HOME" f="$TARGET_HOME/config/application.yaml" bak tmp offset
  [ -f "$f" ] && [ ! -L "$f" ] || finish 1 "$f is missing or not a regular file"
  if grep -q '^  plain-http:' "$f"; then finish 1 "$f already has an api.plain-http block; it was not changed"; fi
  bak="$f.before-network-listener.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p -- "$f" "$bak" || finish 1 "cannot back up $f"
  tmp="$(mktemp "$(dirname "$f")/.application.yaml.XXXXXX")" || finish 1 "cannot stage the new configuration"
  if ! awk -v bind="$API_BIND" -v clients="$API_CLIENTS" '
      /^[A-Za-z_][A-Za-z0-9_-]*:/ { sect = $1; sub(/:.*/, "", sect) }
      sect == "api" && /^  bind-address:/ && !done {
        print "  bind-address: \"" bind "\""
        print "  plain-http:"
        print "    client-addresses: \"" clients "\""
        done = 1; next
      }
      { print }
      END { if (!done) exit 3 }' "$f" > "$tmp" \
     || ! chown --reference="$f" -- "$tmp" || ! chmod --reference="$f" -- "$tmp" || ! mv -f -T -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    finish 1 "could not set the network listener in $f (no api.bind-address line?); the file was not changed"
  fi
  log "application.yaml: api.bind-address $API_BIND, api.plain-http.client-addresses $API_CLIENTS (backup $bak)"
  if ! run_quiet "config-migrate.sh validate" ops_run config-migrate.sh validate --home "$h"; then
    cp -p -- "$bak" "$f"
    finish 1 "Oracle OPS does not accept the network listener $API_BIND (details in the log). The original configuration was restored; Oracle OPS keeps running on 127.0.0.1"
  fi
  offset="$(log_size "$h")"
  if run_quiet "systemctl restart $UNIT_NAME" restart_service && wait_for_routes "$h" "$offset" > /dev/null; then
    NETWORK_OFFSET="$offset"
    say "      The REST API now listens on $API_BIND:$API_PORT for $API_CLIENTS (backup: $bak)."
    return 0
  fi
  cp -p -- "$bak" "$f"
  run_quiet "systemctl restart $UNIT_NAME (original configuration)" restart_service || true
  finish 1 "Oracle OPS did not start with the network listener $API_BIND:$API_PORT (see $h/$SERVICE_LOG_REL). The original configuration was restored and the service restarted on 127.0.0.1"
}

# show_keys_at_end: both keys with their APEX Web Credential settings, then the screen is cleared on Enter.
show_keys_at_end() {
  local a url
  url="$(listener_url "$API_BIND" "$API_PORT")"
  echo
  say "      ===================== REST API keys for the APEX Web Credentials ====================="
  say "      Shown once here (menu 7 'View API Keys' shows them again). They are not in any log."
  show_api_key read "$url" || true
  show_api_key control "$url" || true
  echo
  printf '      Enter both in APEX, then press Enter to clear the screen: '
  read_line a || echo
  clear_screen
}

# ---------------------------------------------------------------------------------------------------------------------------
# The action
# ---------------------------------------------------------------------------------------------------------------------------

op_install() {
  local rc=0 state offset loop_bind
  OPERATION="installation"; STAGE_TOTAL=9
  stage 1 "Checking the system (read-only)..."
  check_prerequisites
  if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
    describe_installation
    if [ -n "$INST_HOME" ] && pinned_release_running; then
      SUCCESS_TEXT="Oracle OPS $OPS_VERSION is already installed at $INST_HOME and running. Nothing was changed."
      finish 0
    fi
    finish 6 "Oracle OPS is already installed${INST_HOME:+ at $INST_HOME}${INST_RELEASE:+ (release $INST_RELEASE)}. Choose 'Upgrade Existing Installation' to install release $OPS_VERSION, or 'Uninstall Oracle OPS' first"
  fi
  discover_report
  stage 2 "Installation settings (nothing is changed yet)..."
  ask_home
  state="$(home_state "$TARGET_HOME")"
  log "installation directory state: $state"
  case "$state" in
    new) ;;
    partial)
      say "      $TARGET_HOME holds an incomplete Oracle OPS installation from an earlier run."
      confirm_yes "Complete that installation?" || finish 5 "the earlier installation was left as it is"
      ;;
    symlink) finish 6 "$TARGET_HOME is a symbolic link; choose the real directory" ;;
    *) finish 6 "$TARGET_HOME exists and is not an Oracle OPS installation directory; choose a new or empty directory" ;;
  esac
  disk_check_home "$TARGET_HOME"
  ask_service_account
  ask_db_target
  ask_api_listener
  stage 3 "Review..."
  show_install_review
  confirm_yes "Install Oracle OPS with these settings?" || finish 5 "the installation was not confirmed; nothing was changed"
  stage 4 "Database prerequisites (DBA)..."
  db_schema_stage
  stage 5 "Configuring source..."
  get_source
  stage 6 "Creating the Oracle OPS database objects..."
  say "      Installing the private Java runtime of Oracle OPS $OPS_VERSION (needed to talk to the database)..."
  run_quiet "provision-java.sh --home $TARGET_HOME --group $SVC_GROUP" ops_run provision-java.sh --home "$TARGET_HOME" \
    --group "$SVC_GROUP" ${JAVA_ARCHIVE:+--archive "$JAVA_ARCHIVE"} \
    || finish 1 "the private Java runtime could not be installed (see the log; for a host without internet access use --java-archive)"
  db_objects_stage
  stage 7 "Creating the REST API keys..."
  create_api_keys "$SVC_GID"
  stage 8 "Installing Oracle OPS..."
  if valid_loopback "$API_BIND"; then loop_bind="$API_BIND"; else loop_bind="$DEFAULT_API_BIND"; fi
  offset="$(log_size "$TARGET_HOME")"
  say "      The Oracle OPS setup assistant now asks for the $DB_RUNTIME password (it tests the login before storing it),"
  say "      the node name and the optional EBS settings. The other answers are passed to it. Its messages are shown"
  say "      below and recorded in the log."
  say "------------------------------------------------------------------------------------------"
  run_interactive "deploy-oracle-ops.sh --home $TARGET_HOME --user $SVC_USER --group $SVC_GROUP --db-host $DB_HOST --db-port $DB_PORT --db-service $DB_SERVICE --db-user $DB_RUNTIME --enable-api --api-bind-address $loop_bind --api-port $API_PORT" \
    ops_run deploy-oracle-ops.sh --home "$TARGET_HOME" --user "$SVC_USER" --group "$SVC_GROUP" \
      --db-host "$DB_HOST" --db-port "$DB_PORT" --db-service "$DB_SERVICE" --db-user "$DB_RUNTIME" \
      --enable-api --api-bind-address "$loop_bind" --api-port "$API_PORT" ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} || rc=$?
  say "------------------------------------------------------------------------------------------"
  if [ "$rc" != 0 ]; then
    finish 1 "the Oracle OPS setup assistant did not complete (exit $rc). The database objects and the API key files were kept; the next Fresh Installation reuses them"
  fi
  if ! valid_loopback "$API_BIND"; then
    say "      Moving the REST API to $API_BIND:$API_PORT..."
    set_network_listener
  fi
  stage 9 "Final validation..."
  install_final_checks "$TARGET_HOME" "$offset" "${NETWORK_OFFSET:-$offset}"
  [ -z "$FINAL_FAILS" ] || finish 1 "the installation is not complete: $FINAL_FAILS"
  show_keys_at_end
  SUCCESS_TEXT="Oracle OPS installation completed successfully.
Release $OPS_VERSION (commit ${OPS_COMMIT:0:7}) is running from $TARGET_HOME as $SVC_USER:$SVC_GROUP.
Database: $DB_HOST:$DB_PORT/$DB_SERVICE (objects in $DB_OWNER, service login $DB_RUNTIME).
REST API: $(listener_url "$API_BIND" "$API_PORT")api/$API_CATALOGUE_VERSION/${API_CLIENTS:+ for $API_CLIENTS}. Keys: menu 7 'View API Keys'.
Start/stop (POST) stays off (ebs.control.enabled: false).
Oracle APEX is not part of this installer; configure its Web Credentials separately."
  finish 0
}
