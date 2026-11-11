#!/bin/bash
# Oracle OPS Installer library: "View Configuration" (0.3.0, read-only)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# Shows the installed application.yaml and the METADATA of the credential files. application.yaml holds no secret by
# Oracle OPS's contract (secrets live only in /etc/oracle-ops); as a safety net, any non-comment line whose key names a
# password, secret, token or credential is shown with its value masked. Credential files are never opened here.

# mask_config_stream: application.yaml on stdin -> the same lines, values of secret-looking keys replaced, control
# characters removed.
mask_config_stream() {
  awk '
    /^[ \t]*#/ { print; next }
    {
      line = $0; low = tolower($0)
      if (match(low, /^[ \t]*[a-z0-9_.-]*(password|passwd|secret|token|credential)[a-z0-9_.-]*[ \t]*:[ \t]*[^ \t#]/)) {
        key = substr(line, 1, index(line, ":"))
        print key " ******** (masked by the installer)"
        next
      }
      print
    }
  ' | tr -d '\000-\010\013-\037\177'
}

op_view_config() {
  local f meta item name kind
  OPERATION="configuration display"
  require_installation
  f="$INST_HOME/config/application.yaml"
  say "      Oracle OPS at $INST_HOME (release ${INST_RELEASE:-unknown}, service account $INST_USER:$INST_GROUP)"
  if [ -L "$f" ] || [ ! -f "$f" ]; then finish 1 "$f is missing or not a regular file"; fi
  meta="$(stat -c '%U:%G %a, %s bytes, modified %y' -- "$f" 2>/dev/null | sed 's/\.[0-9]* / /')"
  say "      Configuration file: $f ($meta)"
  say "      ------------------------------------------------------------------------------------------"
  mask_config_stream < "$f" | sed 's/^/      | /'
  say "      ------------------------------------------------------------------------------------------"
  say "      Credential files in $CRED_DIR (contents are never shown here; API keys: menu 'View API Keys'):"
  for item in $CRED_FILES; do
    name="${item%%:*}"
    if [ -L "$CRED_DIR/$name" ]; then kind="a symbolic link"
    elif [ -f "$CRED_DIR/$name" ]; then kind="$(stat -c '%U:%G %a, modified %y' -- "$CRED_DIR/$name" 2>/dev/null | sed 's/\.[0-9]* / /')"
    elif [ -e "$CRED_DIR/$name" ]; then kind="not a regular file"
    else kind="not present"; fi
    printf '        %-26s %s\n' "$name" "$kind"
  done
  log "configuration displayed: $f (secret-looking values masked)"
  SUCCESS_TEXT="No changes were made."
  finish 0
}
