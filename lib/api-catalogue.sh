#!/bin/bash
# Oracle OPS Installer library: the REST API catalogue of the pinned Oracle OPS release, and "View APIs" (0.3.0)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# The catalogue is a maintained registry for OPS_VERSION / OPS_COMMIT (oracle-ops-installer.sh). It is checked against the
# route constants in that commit's source by tests/api-catalogue-check.py (run by tests/run-tests.sh when the local Oracle OPS
# repository holds the pinned commit), so a moved pin with a changed route set fails the tests until this file is updated.
# Status is never guessed: it comes from the line Oracle OPS itself logs at start-up, "API routes served: [...]", or
# "REST API is disabled (api.enabled=false)", in the installed service log (read-only). No key is ever shown here.

API_CATALOGUE_VERSION="v1"   # ApiService.API_VERSION of the pinned release

# One API per line: number|method|path|group|access|key|exposure|condition|purpose|parameters|example body|example response
api_catalogue_rows() {
  cat <<'ROWS'
1|GET|/api/v1/about|Service|read-only|read|this host; also the allowed APEX/ORDS server when the API listens on a network address|api.enabled: true|Application name and version, API version, Java runtime, service state and whether EBS integration is enabled.|none|-|data: application, version, api_version, java {version, vendor}, service_state, ebs_integration
2|GET|/api/v1/ops/status|Service|read-only|read|this host; also the allowed APEX/ORDS server when the API listens on a network address|api.enabled: true|Health of the service and its dependencies: service state, database (probe cached for api.status.database-cache-seconds), EBS integration, API, start/stop control.|none|-|data: service, database {state, response_millis, checked_at}, ebs, api, control
3|GET|/api/v1/linux/host|Host monitoring|read-only|read|loopback only|api.enabled: true with a loopback api.bind-address|Host metrics: identity, uptime, CPU utilisation and load, memory, swap, file systems.|none|-|data: collected_at, collection_millis, identity, uptime, cpu, memory, swap, filesystems
4|GET|/api/v1/node/identity|Host monitoring|read-only|read|loopback only|api.enabled: true with a loopback api.bind-address|Node identity (host name, FQDN, OS, kernel, architecture, uptime, processors), executed and recorded as an OPS_RUN.|none|-|data: operation_code, hostname, fqdn, fqdn_verified, os_name, os_version, kernel_version, architecture, uptime_seconds, available_processors; run_id
5|GET|/api/v1/managed-servers|EBS WebLogic|read-only|read|loopback only|api.enabled: true, loopback api.bind-address, ebs.enabled: true|Status of every Managed Server of this node's EBS context file, checked one at a time with the EBS status utility; recorded as an OPS_RUN.|none|-|data: operation_code, collected_at, collection_millis, collection, summary {total, running, stopped, other, unknown}, servers [{name, service_type, status, state, error_code, checked_at, duration_millis}]; run_id
6|POST|/api/v1/managed-servers/{name}/start|EBS WebLogic|control/action|control|loopback only|api.enabled, loopback, ebs.enabled with edition run, ebs.control.enabled: true, ops.node, the control key file|Start one Managed Server. Asynchronous: answers 202 at once; poll the run for the result.|{name}: a Managed Server name from GET /api/v1/managed-servers. JSON body: confirm_server_name (required, must equal {name}); requested_by (required, 1-255 printable characters, recorded for audit); reason (optional, at most 400 characters).|{"confirm_server_name": "<name>", "requested_by": "<APEX user>", "reason": "<text>"}|202, status SUBMITTED, data: action_id, server_name, action, mode, replay, poll (/api/v1/runs/<run_id>); run_id. Errors: 400, 403 (read key), 409 in progress, 503 busy
7|POST|/api/v1/managed-servers/{name}/stop|EBS WebLogic|control/action|control|loopback only|api.enabled, loopback, ebs.enabled with edition run, ebs.control.enabled: true, ops.node, the control key file|Graceful stop of one Managed Server. Asynchronous: answers 202 at once; poll the run for the result. No forced stop.|{name}: as for start. JSON body: confirm_server_name (required, must equal {name}); requested_by (required); reason (optional); mode (optional, only GRACEFUL); acknowledge_outage (optional, true or false).|{"confirm_server_name": "<name>", "requested_by": "<APEX user>", "reason": "<text>", "mode": "GRACEFUL", "acknowledge_outage": true}|202 as for start (mode GRACEFUL). Errors: 400 (FORCE is UNSUPPORTED_MODE), 403 (read key), 409, 503
8|GET|/api/v1/runs/{run_id}|EBS WebLogic|read-only|read or control|loopback only|served together with start/stop (ebs.control.enabled: true)|The state and result of a start/stop run, for polling after a 202.|{run_id}: the number returned by start/stop.|-|data: run and action state (action_id, server_name, action, action_state, state_before, state_after, submitted_at, started_at, ended_at, outcome, result_code, message, ...); run_id
ROWS
}

API_STATE=""     # not-installed | stopped | disabled | routes | unknown
API_SERVED=""    # the routes Oracle OPS reported, ", "-separated, as logged

# api_runtime_state: what the installed service reported about its routes (read-only: unit, systemctl is-active, log tail).
api_runtime_state() {
  local f line
  API_STATE="not-installed"; API_SERVED=""
  if [ ! -f "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then return 0; fi
  describe_installation
  [ -n "$INST_HOME" ] || { API_STATE="unknown"; return 0; }
  if [ "$INST_ACTIVE" != yes ]; then API_STATE="stopped"; return 0; fi
  f="$INST_HOME/$SERVICE_LOG_REL"
  API_STATE="unknown"
  if [ ! -f "$f" ] || [ -L "$f" ]; then return 0; fi
  line="$(tail -n "$STATUS_LOG_TAIL" -- "$f" 2>/dev/null | grep -F -e "$API_ROUTES_LINE" -e "$API_DISABLED_LINE" | tail -n 1)" || line=""
  case "$line" in
    *"$API_DISABLED_LINE"*) API_STATE="disabled" ;;
    *"$API_ROUTES_LINE"*)
      API_SERVED="${line#*"$API_ROUTES_LINE"}"; API_SERVED="${API_SERVED%%]*}"
      API_STATE="routes" ;;
  esac
}

# api_route_status <path>: the status word for one API from API_STATE / API_SERVED.
api_route_status() {
  case "$API_STATE" in
    not-installed) printf 'NOT INSTALLED' ;;
    stopped) printf 'SERVICE STOPPED' ;;
    disabled) printf 'API DISABLED' ;;
    routes) case ", $API_SERVED, " in *", $1, "*) printf 'DEPLOYED' ;; *) printf 'NOT DEPLOYED' ;; esac ;;
    *) printf 'UNKNOWN' ;;
  esac
}

api_show_details() {   # api_show_details <row>
  local n m p g a k e c pu pa b r
  IFS='|' read -r n m p g a k e c pu pa b r <<< "$1"
  echo
  say "      ---- API $n: $m $p ----"
  printf '        %-17s %s\n' "Group:" "$g" "Purpose:" "$pu" "Access level:" "$a" "Version:" "$API_CATALOGUE_VERSION (Oracle OPS $OPS_VERSION)" \
    "Status:" "$(api_route_status "$p")" "Exposure:" "$e" "Deployed when:" "$c"
  printf '        %-17s %s\n' "Authentication:" "Authorization: Bearer <$k key>  (keys: menu 'View API Keys'; never shown here)"
  if [ "$m" = POST ]; then
    printf '        %-17s %s\n' "Headers:" "Authorization (required); Content-Type: application/json (required);" \
      "" "X-Request-Id (optional, 1-64 of A-Z a-z 0-9 . _ -; repeating it returns the existing run)"
  else
    printf '        %-17s %s\n' "Headers:" "Authorization (required); X-Request-Id (optional, 1-64 of A-Z a-z 0-9 . _ -)"
  fi
  printf '        %-17s %s\n' "Parameters:" "$pa"
  [ "$b" = "-" ] || printf '        %-17s %s\n' "Example body:" "$b"
  printf '        %-17s %s\n' "Response:" "{request_id, status, data, error, run_id} - $r"
}

op_view_apis() {
  local row n m p g a k e c pu pa b r choice rows=()
  OPERATION="API catalogue display"
  api_runtime_state
  log "API catalogue: state=$API_STATE"
  say "      Oracle OPS REST API catalogue - Oracle OPS $OPS_VERSION (commit ${OPS_COMMIT:0:7}), API $API_CATALOGUE_VERSION"
  case "$API_STATE" in
    not-installed) say "      Oracle OPS is not installed on this host: the catalogue shows what a Fresh Installation provides." ;;
    stopped) say "      $UNIT_NAME is not running: no API is being served right now." ;;
    disabled) say "      The REST API is disabled in the installed configuration (api.enabled: false)." ;;
    unknown) say "      The service log has no recent route line; the deployed state cannot be determined." ;;
    routes) say "      Status is taken from the routes the running service reported at start-up." ;;
  esac
  if [ -n "$INST_RELEASE" ] && [ "$INST_RELEASE" != "$OPS_VERSION" ]; then
    say "      NOTE: the installed release is $INST_RELEASE; this catalogue describes $OPS_VERSION."
  fi
  echo
  printf '      %-3s %-5s %-38s %-15s %-16s %s\n' "#" "Verb" "Endpoint" "Access" "Key" "Status"
  while IFS= read -r row; do
    rows+=("$row")
    IFS='|' read -r n m p g a k e c pu pa b r <<< "$row"
    printf '      %-3s %-5s %-38s %-15s %-16s %s\n' "$n" "$m" "$p" "$a" "$k" "$(api_route_status "$p")"
  done < <(api_catalogue_rows)
  echo
  say "      Every API needs the header  Authorization: Bearer <key>. The read key works for GET; the control key only"
  say "      for start/stop and run look-ups. Start/stop (POST) is served only when ebs.control.enabled is true."
  while :; do
    echo
    printf '      Enter an API number for details, or press Enter to finish: '
    read_line choice || { echo; break; }
    [ -n "$choice" ] || break
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#rows[@]}" ]; then
      api_show_details "${rows[$((choice - 1))]}"
    else
      say "      Please enter a number from 1 to ${#rows[@]}, or press Enter."
    fi
  done
  SUCCESS_TEXT="No changes were made."
  finish 0
}
