#!/bin/bash
# Oracle OPS Installer library: action: de-install
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

op_deinstall() {
  local h retired="" e before
  OPERATION="de-installation"; STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then
    describe_installation
    h="$INST_HOME"
    [ -n "$h" ] || finish 1 "the installed $UNIT_NAME does not name a usable installation directory"
  else
    say "      No Oracle OPS service is defined; enter the directory of the installation to remove."
    ask_home
    h="$TARGET_HOME"
  fi
  if [ -L "$h" ] || [ ! -d "$h/releases" ]; then finish 6 "no Oracle OPS installation was found at $h"; fi
  say "      Oracle OPS at $h will be stopped and disabled, its systemd unit and log-rotation file removed,"
  say "      and $h renamed to $h.retired-<time>. Nothing is deleted; $CRED_DIR and OS accounts are not changed."
  confirm_yes "De-install Oracle OPS now?" || finish 5 "the de-installation was not confirmed; nothing was changed"
  stage 3 "Configuring source..."
  get_source
  stage 4 "De-installing Oracle OPS..."
  before="$(find "$(dirname "$h")" -mindepth 1 -maxdepth 1 -name "$(basename "$h").retired-*" -printf '%f\n' 2>/dev/null | sort)"
  run_quiet "service-identity.sh retire (dry run)" ops_run service-identity.sh retire --home "$h" \
    || finish 1 "the de-installation check failed; nothing was changed"
  run_quiet "service-identity.sh retire --apply" ops_run service-identity.sh retire --home "$h" --apply \
    || finish 1 "the Oracle OPS de-installation script failed"
  stage 5 "Finalizing de-installation..."
  while IFS= read -r e; do
    printf '%s\n' "$before" | grep -qxF -- "$e" || retired="$(dirname "$h")/$e"
  done < <(find "$(dirname "$h")" -mindepth 1 -maxdepth 1 -name "$(basename "$h").retired-*" -printf '%f\n' 2>/dev/null | sort)
  [ ! -e "$h" ] && [ ! -L "$h" ] || finish 1 "$h still exists after the de-installation"
  [ -n "$retired" ] && [ -d "$retired" ] || finish 1 "the renamed installation directory could not be found"
  if [ -f "$UNIT_FILE" ] && [ "$(unit_home)" = "$h" ]; then finish 1 "the $UNIT_NAME service definition still points to $h"; fi
  if [ -n "$INST_HOME" ] && service_active; then finish 1 "$UNIT_NAME is still running"; fi
  log "de-installation verified: $h renamed to $retired"
  SUCCESS_TEXT="Oracle OPS de-installation completed successfully.
The former installation was renamed to $retired (nothing was deleted).
Credentials in $CRED_DIR and OS accounts were not changed."
  finish 0
}
