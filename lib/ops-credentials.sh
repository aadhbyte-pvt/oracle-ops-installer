#!/bin/bash
# Oracle OPS Installer library: action: Reconfigure Installation (credentials, REST API keys)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

db_password_guidance() {
  say "      Oracle OPS reads its database password from $CRED_DIR/database.credentials."
  say "      No Oracle OPS tool replaces that file. To change the password:"
  say "        1. Have the DBA change the password of the Oracle OPS runtime account."
  say "        2. As root, edit $CRED_DIR/database.credentials and set the new db.password value"
  say "           (Java properties format: write a backslash as \\\\ and a space as '\\ ')."
  say "           Keep the file owned by root, group = the service group, mode 0640."
  say "        3. Restart Oracle OPS:  systemctl restart $UNIT_NAME"
  say "        4. Check for \"$DB_HEALTHY_LINE\" in <installation directory>/$SERVICE_LOG_REL."
  say "      Never put the password on a command line."
}

# Reconfigure Installation (0.3.0): the credential updates of 0.2.0 ("Update credentials") plus the API key regeneration.
op_reconfigure() {
  local c rc=0 f st
  OPERATION="credential update"
  echo
  say "  What do you want to change?"
  say "    1) WebLogic administration account (stored for Oracle OPS)"
  say "    2) Database password of the Oracle OPS runtime account"
  say "    3) Regenerate the REST API keys"
  say "    4) Cancel"
  choose c "  Choose 1-4: " 1 2 3 4
  case "$c" in
    4) finish 5 "nothing was changed" ;;
    3) op_regenerate_api_keys ;;
    2) echo; db_password_guidance; SUCCESS_TEXT="No changes were made."; finish 0 ;;
  esac
  STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  require_installation
  if [ ! -d "$CRED_DIR" ] || [ -L "$CRED_DIR" ]; then finish 6 "the Oracle OPS credential directory $CRED_DIR does not exist"; fi
  stage 3 "Configuring source..."
  get_source
  stage 4 "Updating the WebLogic credential..."
  say "      The Oracle OPS credential manager now asks for the WebLogic user name and password"
  say "      (input hidden). Its messages are shown below and recorded in the log."
  say "------------------------------------------------------------------------------------------"
  run_interactive "manage-app-credentials.sh" ops_run manage-app-credentials.sh || rc=$?
  say "------------------------------------------------------------------------------------------"
  case "$rc" in
    0) ;;
    3) finish 5 "the existing WebLogic credential was kept" ;;
    *) finish 1 "the Oracle OPS credential manager did not complete (exit $rc)" ;;
  esac
  stage 5 "Finalizing..."
  f="$CRED_DIR/apps.credentials"
  st="$(stat -c '%a %u %g %h' "$f" 2>/dev/null)" || st=""
  if [ -L "$f" ] || [ ! -f "$f" ] || [ "$st" != "400 $(getent passwd "$INST_USER" | cut -d: -f3) $(getent group "$INST_GROUP" | cut -d: -f3) 1" ]; then
    finish 1 "the stored WebLogic credential file does not have the expected owner and permissions"
  fi
  log "credential file verified: $f mode 0400 owner $INST_USER:$INST_GROUP (content not read)"
  SUCCESS_TEXT="WebLogic credential updated successfully. (Oracle OPS was not restarted.)"
  finish 0
}

# Reconfigure > Regenerate the REST API keys: new key(s) in /etc/oracle-ops, then (only if the operator says so) a restart.
# Oracle OPS reads the keys at start-up only, and APEX keeps sending the old key until its Web Credential is updated, so the
# operator chooses when to restart. No old key is kept anywhere (an old key is not worth keeping: it is replaced, not lost).
op_regenerate_api_keys() {
  local c which gid offset waited=0 line
  OPERATION="API key regeneration"; STAGE_TOTAL=3
  stage 1 "Checking the current installation..."
  require_installation
  gid="$(group_gid "$INST_GROUP")"
  [[ "$gid" =~ ^[0-9]+$ ]] || finish 1 "the service group $INST_GROUP does not exist on this host"
  echo
  say "      Which key do you want to replace?"
  say "        1) Read key (GET APIs)"
  say "        2) Control key (POST APIs: start/stop)"
  say "        3) Both"
  say "        4) Cancel"
  choose c "      Choose 1-4: " 1 2 3 4
  case "$c" in 1) which=read ;; 2) which=control ;; 3) which=both ;; 4) finish 5 "no key was replaced" ;; esac
  say "      The new key takes effect when Oracle OPS restarts. Until the APEX Web Credential holds the new key"
  say "      and Oracle OPS has restarted, APEX calls that use this key fail with HTTP 401."
  confirm_yes "Replace the selected key(s)?" || finish 5 "no key was replaced"
  stage 2 "Replacing the API key(s)..."
  regenerate_api_keys "$which" "$gid"
  stage 3 "Restart..."
  if ! confirm_yes "Restart Oracle OPS now so the new key(s) take effect?"; then
    SUCCESS_TEXT="The API key(s) were replaced; Oracle OPS was NOT restarted and still accepts the old key(s).
Update the APEX Web Credential(s) (menu 7 'View API Keys' shows the new key), then: systemctl restart $UNIT_NAME"
    finish 0
  fi
  offset="$(log_size "$INST_HOME")"
  run_quiet "systemctl restart $UNIT_NAME" restart_service || finish 1 "systemctl restart $UNIT_NAME failed; the new key file(s) are in place"
  while [ "$waited" -lt "$RESTART_WAIT_SECONDS" ]; do
    line="$(routes_since "$INST_HOME" "$offset")"
    if [ -n "$line" ] && service_active; then break; fi
    sleep 2; waited=$((waited + 2))
  done
  [ -n "$line" ] && service_active || finish 1 "Oracle OPS was restarted but did not report its API routes within $RESTART_WAIT_SECONDS seconds; check: systemctl status $UNIT_NAME"
  line="${line#*"$API_ROUTES_LINE"}"; log "restart verified, routes: ${line%%]*}"
  SUCCESS_TEXT="The API key(s) were replaced and Oracle OPS was restarted with them.
Update the APEX Web Credential(s) now: menu 7 'View API Keys' shows the new key."
  finish 0
}
