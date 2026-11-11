#!/bin/bash
# Oracle OPS Installer library: the two REST API keys (0.3.0) - creation, rotation, strict reading, "View API Keys"
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# The files are Oracle OPS's own fixed contract (ApiTokenLoader; deploy/README.md "Secrets"):
#   /etc/oracle-ops/api.credentials           api.token=<read key>              GET APIs        root:<service group> 0640
#   /etc/oracle-ops/api-control.credentials   api.control.token=<control key>   POST APIs       root:<service group> 0640
# Oracle OPS needs at least 32 characters and two DIFFERENT keys (ApiTokenLoader.requireDistinct). The installer generates
# 32 random bytes from /dev/urandom per key, written as 64 lower-case hex characters.
#
# Secret handling: a key is produced by od into a command substitution (a pipe, never an argument or the environment),
# kept in a local, non-exported variable, written with the printf builtin into a mktemp file inside /etc/oracle-ops that
# gets its owner and mode BEFORE it is linked into place, and is never logged: while a key is in memory it is also listed in
# API_KEY_REDACT_1/2, which sanitize_stream removes from every logged line. A new key file never replaces an existing one
# (ln, not mv); only Reconfigure > "Regenerate the API keys" replaces a key file, after a typed confirmation.

# api_key_spec <read|control>: sets AK_FILE (full path) and AK_PROP (the property name) from API_KEY_FILES.
AK_FILE=""; AK_PROP=""
api_key_spec() {
  local item name prop scope
  AK_FILE=""; AK_PROP=""
  for item in $API_KEY_FILES; do
    name="${item%%:*}"; prop="${item#*:}"; scope="${prop#*:}"; prop="${prop%%:*}"
    if [ "$scope" = "$1" ]; then AK_FILE="$CRED_DIR/$name"; AK_PROP="$prop"; return 0; fi
  done
  return 1
}

api_key_label() {
  case "$1" in
    read) printf 'read key (GET APIs)' ;;
    control) printf 'control key (POST APIs: start/stop)' ;;
  esac
}

# The APEX Web Credential each key belongs to (static IDs as documented by Oracle OPS: docs/08 section 7.2, docs/12).
api_key_static_id() {
  case "$1" in
    read) printf 'OPS_API_TOKEN' ;;
    control) printf 'oracle-ops-api-token-action' ;;
  esac
}

# generate_api_key <variable>: API_KEY_BYTES random bytes as lower-case hex; false if the random source failed.
generate_api_key() {
  local _k
  _k="$(od -An -tx1 -v -N"$API_KEY_BYTES" "$RANDOM_SOURCE" 2>/dev/null | tr -d ' \n')" || _k=""
  if [[ ! "$_k" =~ ^[0-9a-f]+$ ]] || [ "${#_k}" -ne $((API_KEY_BYTES * 2)) ]; then _k=""; return 1; fi
  printf -v "$1" '%s' "$_k"
  _k=""
}

# key_file_meta <file>: "<owner>:<group> <mode> <links> <modified>" of the file itself (a link is not followed).
key_file_meta() { { stat -c '%U:%G %a %h %y' -- "$1" 2>/dev/null || true; } | cut -d. -f1; }

# key_meta_ok <file> <gid>: the Oracle OPS permission contract: a regular file, root:<gid>, mode 0640, exactly one link.
key_meta_ok() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u %g %a %h' -- "$1" 2>/dev/null)" = "$ADMIN_UID $2 640 1" ]
}

# read_api_key <file> <property> <variable>: the key value, strictly. Returns 0 with the value set, 2 when the file must not
# be read (missing, a symbolic link, not a regular file, more than one hard link), 1 when its content is not exactly one
# "<property>=<value>" line with a value of at least API_KEY_MIN_CHARS printable characters (comments and blank lines are
# allowed, as in a Java properties file). The value never leaves this function except through the variable.
read_api_key() {
  local _f="$1" _p="$2" _line _v="" _n=0 _links
  if [ -L "$_f" ] || [ ! -f "$_f" ]; then return 2; fi
  _links="$(stat -c %h -- "$_f" 2>/dev/null)" || return 2
  [ "$_links" = 1 ] || return 2
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    case "$_line" in ''|'#'*|'!'*) continue ;; esac
    if [[ "$_line" =~ ^${_p//./\\.}[[:space:]]*[=:][[:space:]]*(.*)$ ]]; then
      _v="${BASH_REMATCH[1]}"; _v="${_v%"${_v##*[![:space:]]}"}"; _n=$((_n + 1))
    else
      _v=""; return 1
    fi
  done < "$_f"
  if [ "$_n" != 1 ] || [ "${#_v}" -lt "$API_KEY_MIN_CHARS" ] || [[ ! "$_v" =~ ^[!-~]+$ ]]; then _v=""; return 1; fi
  printf -v "$3" '%s' "$_v"
  _v=""
}

# ensure_cred_dir <gid>: /etc/oracle-ops as Oracle OPS's ownership model has it (root:<group> 0750). An existing directory
# is used as it is (never re-owned here; Oracle OPS's setup assistant normalises it), but it must be a real directory owned
# by root.
ensure_cred_dir() {
  if [ -L "$CRED_DIR" ]; then echo "$CRED_DIR is a symbolic link"; return 1; fi
  if [ -e "$CRED_DIR" ]; then
    [ -d "$CRED_DIR" ] || { echo "$CRED_DIR exists and is not a directory"; return 1; }
    [ "$(stat -c %u -- "$CRED_DIR")" = "$ADMIN_UID" ] || { echo "$CRED_DIR is not owned by root"; return 1; }
    return 0
  fi
  mkdir -m 0750 -- "$CRED_DIR" || { echo "cannot create $CRED_DIR"; return 1; }
  chown "$ADMIN_UID:$1" -- "$CRED_DIR" && chmod 0750 -- "$CRED_DIR" || { echo "cannot set the owner of $CRED_DIR"; return 1; }
  log "created $CRED_DIR (root:$1 0750)"
}

# stage_key_file <file> <property> <value> <gid>: a new file beside <file> with the final owner and mode; prints its path.
stage_key_file() {
  local tmp
  tmp="$(mktemp "$(dirname "$1")/.$(basename "$1").staged.XXXXXX")" || return 1
  if ! { printf '%s=%s\n' "$2" "$3" > "$tmp" && chown "$ADMIN_UID:$4" -- "$tmp" && chmod 0640 -- "$tmp"; }; then
    rm -f -- "$tmp"; return 1
  fi
  printf '%s' "$tmp"
}

# install_new_key_file <file> <property> <value> <gid>: creates <file>; never replaces an existing one.
install_new_key_file() {
  local tmp rc=0
  tmp="$(stage_key_file "$@")" || return 1
  ln -- "$tmp" "$1" 2>/dev/null || rc=1
  rm -f -- "$tmp"
  [ "$rc" = 0 ] && key_meta_ok "$1" "$4"
}

# replace_key_file <file> <property> <value> <gid>: atomically replaces an existing regular key file (rename in place).
replace_key_file() {
  local tmp
  if [ -L "$1" ] || [ ! -f "$1" ]; then return 1; fi
  tmp="$(stage_key_file "$@")" || return 1
  mv -f -T -- "$tmp" "$1" || { rm -f -- "$tmp"; return 1; }
  key_meta_ok "$1" "$4"
}

# create_api_keys <gid>: Fresh Installation, after the confirmation. Creates each key file that does not exist; an existing
# valid file is kept as it is (a re-run after a failed setup reuses it). Never prints or logs a key.
create_api_keys() {
  local gid="$1" msg scope r_val="" c_val="" new attempt
  KEYS_CREATED=""; KEYS_KEPT=""
  msg="$(ensure_cred_dir "$gid")" || finish 1 "cannot prepare the credential directory: $msg"
  for scope in read control; do
    api_key_spec "$scope"
    if [ -e "$AK_FILE" ] || [ -L "$AK_FILE" ]; then
      new=""
      read_api_key "$AK_FILE" "$AK_PROP" new || finish 1 "$AK_FILE already exists but is not a valid key file (it was not changed). Fix or remove it, then run the installer again"
      if [ "$scope" = read ]; then r_val="$new"; API_KEY_REDACT_1="$new"; else c_val="$new"; API_KEY_REDACT_2="$new"; fi
      new=""
      KEYS_KEPT="$KEYS_KEPT $AK_FILE"
      say "      Kept the existing $(api_key_label "$scope") in $AK_FILE"
      log "API key file kept (already present, valid format): $AK_FILE"
    fi
  done
  for scope in read control; do
    api_key_spec "$scope"
    if [ -e "$AK_FILE" ] || [ -L "$AK_FILE" ]; then continue; fi
    new=""
    for attempt in 1 2 3; do
      generate_api_key new || finish 1 "cannot read random data from $RANDOM_SOURCE to generate the $(api_key_label "$scope")"
      if [ "$new" != "$r_val" ] && [ "$new" != "$c_val" ]; then break; fi
      new=""
    done
    [ -n "$new" ] || finish 1 "could not generate two different API keys"
    if [ "$scope" = read ]; then r_val="$new"; API_KEY_REDACT_1="$new"; else c_val="$new"; API_KEY_REDACT_2="$new"; fi
    install_new_key_file "$AK_FILE" "$AK_PROP" "$new" "$gid" \
      || { new=""; finish 1 "could not create $AK_FILE (root:$SVC_GROUP 0640)"; }
    new=""
    KEYS_CREATED="$KEYS_CREATED $AK_FILE"
    say "      Created the $(api_key_label "$scope") in $AK_FILE (root:$SVC_GROUP 0640; not shown)"
    log "API key file created: $AK_FILE (root:$gid 0640; value not logged)"
  done
  if [ -n "$r_val" ] && [ "$r_val" = "$c_val" ]; then
    say "      WARNING: the read key and the control key are identical. Oracle OPS refuses that when start/stop is enabled."
    say "      Use Reconfigure > Regenerate the API keys to replace one of them."
    log "WARNING: the existing read and control keys are identical"
  fi
  r_val=""; c_val=""; API_KEY_REDACT_1=""; API_KEY_REDACT_2=""
  KEYS_CREATED="${KEYS_CREATED# }"; KEYS_KEPT="${KEYS_KEPT# }"
}

# regenerate_api_keys <read|control|both> <gid>: Reconfigure. Replaces the chosen key file(s) with new, different keys.
regenerate_api_keys() {
  local which="$1" gid="$2" scope other new="" other_val="" attempt scopes msg verb
  case "$which" in both) scopes="read control" ;; *) scopes="$which" ;; esac
  for scope in $scopes; do
    api_key_spec "$scope"
    if [ -L "$AK_FILE" ] || { [ -e "$AK_FILE" ] && [ ! -f "$AK_FILE" ]; }; then
      finish 1 "$AK_FILE is a symbolic link or not a regular file; nothing was changed"
    fi
  done
  msg="$(ensure_cred_dir "$gid")" || finish 1 "cannot use the credential directory: $msg"
  for scope in $scopes; do
    if [ "$scope" = read ]; then other=control; else other=read; fi
    other_val=""
    api_key_spec "$other"
    if [ -f "$AK_FILE" ] && [ ! -L "$AK_FILE" ]; then read_api_key "$AK_FILE" "$AK_PROP" other_val || other_val=""; fi
    API_KEY_REDACT_2="$other_val"
    api_key_spec "$scope"
    new=""
    for attempt in 1 2 3; do
      generate_api_key new || finish 1 "cannot read random data from $RANDOM_SOURCE"
      [ "$new" = "$other_val" ] || break
      new=""
    done
    [ -n "$new" ] || finish 1 "could not generate a key different from the $(api_key_label "$other")"
    API_KEY_REDACT_1="$new"
    if [ -f "$AK_FILE" ]; then
      verb="Replaced"
      replace_key_file "$AK_FILE" "$AK_PROP" "$new" "$gid" || { new=""; finish 1 "could not replace $AK_FILE"; }
    else
      verb="Created"
      install_new_key_file "$AK_FILE" "$AK_PROP" "$new" "$gid" || { new=""; finish 1 "could not create $AK_FILE"; }
    fi
    new=""; other_val=""; API_KEY_REDACT_1=""; API_KEY_REDACT_2=""
    say "      $verb the $(api_key_label "$scope") in $AK_FILE (root:$INST_GROUP 0640; not shown)"
    log "API key file ${verb,,}: $AK_FILE (value not logged)"
  done
}

# yaml_api_listener <application.yaml>: prints "<bind-address> <port>" of the api: section, or nothing if either is not a
# plain value. Read-only, line-based (the template's own layout: two-space keys under a top-level "api:").
yaml_api_listener() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk '
    /^[A-Za-z_][A-Za-z0-9_-]*:/ { sect = $1; sub(/:.*/, "", sect); next }
    sect == "api" && /^  bind-address:/ { v = $0; sub(/^  bind-address:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/["\047 \t]/, "", v); bind = v }
    sect == "api" && /^  port:/ { v = $0; sub(/^  port:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/["\047 \t]/, "", v); port = v }
    END { if (bind ~ /^[0-9A-Fa-f.:]+$/ && port ~ /^[0-9]+$/) print bind " " port }
  ' "$1" 2>/dev/null
}

# listener_url <bind> <port>: the base URL APEX uses for this listener (an IPv6 literal in brackets).
listener_url() {
  case "$1" in *:*) printf 'http://[%s]:%s/' "$1" "$2" ;; *) printf 'http://%s:%s/' "$1" "$2" ;; esac
}

# show_api_key <read|control> <base url or empty>: reads one key strictly and prints it with its APEX settings.
show_api_key() {
  local scope="$1" url="$2" v="" rc=0
  api_key_spec "$scope"
  read_api_key "$AK_FILE" "$AK_PROP" v || rc=$?
  if [ "$rc" = 2 ]; then say "      $AK_FILE is missing, a symbolic link or not a single regular file: not displayed."; return 1; fi
  if [ "$rc" != 0 ]; then say "      $AK_FILE does not hold exactly one valid $AK_PROP line: not displayed."; return 1; fi
  API_KEY_REDACT_1="$v"
  echo
  say "      ---- $(api_key_label "$scope") - $AK_FILE ----"
  say "      APEX Web Credential (Workspace Utilities > Web Credentials):"
  say "        Static ID           : $(api_key_static_id "$scope")   (name used in the Oracle OPS documentation)"
  say "        Authentication type : HTTP Header"
  say "        Credential name     : Authorization"
  printf '        Credential secret   : Bearer %s\n' "$v"
  if [ -n "$url" ]; then say "        Valid for URLs      : $url"; else say "        Valid for URLs      : http://<api.bind-address>:<api.port>/"; fi
  v=""; API_KEY_REDACT_1=""
  log "API key displayed on the terminal: $(api_key_label "$scope") from $AK_FILE (value not logged)"
}

op_view_api_keys() {
  local c a scope n=0 present="" meta url="" listener shown=0
  OPERATION="API key display"
  say "      Oracle OPS REST API keys in $CRED_DIR (root only):"
  for scope in read control; do
    api_key_spec "$scope"
    if [ -L "$AK_FILE" ]; then meta="a symbolic link (refused)"
    elif [ -f "$AK_FILE" ]; then meta="$(key_file_meta "$AK_FILE")"; present="$present $scope"; n=$((n + 1))
    elif [ -e "$AK_FILE" ]; then meta="not a regular file (refused)"
    else meta="not present"; fi
    printf '        %-38s %s\n' "$(api_key_label "$scope"):" "$AK_FILE"
    printf '        %-38s %s\n' "" "$meta"
  done
  [ "$n" -gt 0 ] || finish 6 "no API key file exists in $CRED_DIR (Fresh Installation creates both)"
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then
    describe_installation
    if [ -n "$INST_HOME" ]; then
      listener="$(yaml_api_listener "$INST_HOME/config/application.yaml")"
      [ -z "$listener" ] || url="$(listener_url "${listener% *}" "${listener#* }")"
    fi
  fi
  echo
  say "      Which key do you want to display?"
  say "        1) Read key (GET APIs)"
  say "        2) Control key (POST APIs: start/stop)"
  say "        3) Both"
  say "        4) Cancel"
  choose c "      Choose 1-4: " 1 2 3 4
  [ "$c" != 4 ] || finish 5 "no key was displayed"
  echo
  say "      The key will be shown in clear text. Anyone who can see this screen, or its scroll-back, can use it."
  printf '      Type %s to display it: ' "$SHOW_WORD"
  read_line a || { echo; finish 5 "no key was displayed"; }
  [ "$a" = "$SHOW_WORD" ] || finish 5 "no key was displayed"
  log "operator confirmed the display of API key choice $c"
  case "$c" in
    1) show_api_key read "$url" && shown=1 ;;
    2) show_api_key control "$url" && shown=1 ;;
    3) if show_api_key read "$url"; then shown=1; fi; if show_api_key control "$url"; then shown=1; fi ;;
  esac
  [ "$shown" = 1 ] || finish 1 "the selected key could not be displayed"
  echo
  printf '      Press Enter to clear the screen: '
  read_line a || echo
  clear_screen
  SUCCESS_TEXT="The screen was cleared. The keys were not written to any log.
Enter each key in its APEX Web Credential exactly as shown, then close this terminal session."
  finish 0
}
