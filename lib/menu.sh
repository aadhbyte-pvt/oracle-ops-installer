#!/bin/bash
# Oracle OPS Installer library: usage, argument parsing, menu
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. usage, parse_args and menu changed in 0.2.0
# (read-only subcommands, menu items 5-7). The menu changed again in 0.3.0: ten items, each shown with the reason when it
# does not apply to this host (the action itself still refuses with exit 6; the menu text is only a hint).

# ---------------------------------------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: sudo bash $0 [--java-archive FILE]
       sudo bash $0 status   [--home DIR]
       sudo bash $0 validate [--home DIR] [--source-repo DIR]
       bash $0 --help | --version

Interactive installer for Oracle OPS release $OPS_VERSION (Oracle Linux 7, x86_64). Choose one action from the menu:
Fresh Installation, Upgrade, Reconfigure, Validate Environment, View Installation Status, View APIs, View API Keys,
View Configuration, Uninstall. Fresh Installation creates both REST API keys (read and control) in /etc/oracle-ops.
Oracle APEX is not part of this installer.

  --java-archive FILE   a pre-staged copy of the Oracle JDK archive pinned by Oracle OPS, for hosts that cannot
                        reach download.oracle.com (passed to the Oracle OPS scripts, which verify its checksum)
  --help                this text
  --version             installer version and the pinned Oracle OPS release

Read-only checks (root; no terminal and no prompt needed; nothing is installed, changed or restarted):
  status                examine the installed Oracle OPS: unit, installation directory, current release, build commit
                        against the pin, Java runtime, service state and process, service log lines, and the
                        permissions of the configuration and credential files (their contents are never opened)
  validate              status, then the checks of the pinned Oracle OPS release, run from a verified copy taken out of
                        the local Oracle OPS repository (git archive of the pinned commit; no network): the
                        configuration validation and the service-identity check
  --home DIR            the installation directory (default: the one the installed unit names; if both exist they must match)
  --source-repo DIR     validate only: the local Oracle OPS repository (default: $DEFAULT_SOURCE_REPO)
The subcommand must be the first argument. Exit status: 0 no problem found | 1 a check failed | 2 cannot run as invoked |
4 the pinned source could not be verified (validate) | 6 Oracle OPS is not installed. The menu offers the same checks as
items 5 (status) and 4 (validate).

Logs: $LOG_DIR (root only). See README.md.
EOF
}

# parse_check_args <status|validate> [options]: the arguments of a read-only check. Unknown or repeated options and the options
# of the install actions are usage errors (exit 2).
parse_check_args() {
  CLI_MODE="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --home)
        [ "$CLI_HOME_SET" = 0 ] || { usage >&2; die_early "--home was given more than once" 2; }
        [ $# -ge 2 ] || { usage >&2; die_early "--home needs a directory" 2; }
        CLI_HOME="$2"; CLI_HOME_SET=1; shift 2 ;;
      --home=*)
        [ "$CLI_HOME_SET" = 0 ] || { usage >&2; die_early "--home was given more than once" 2; }
        CLI_HOME="${1#--home=}"; CLI_HOME_SET=1; shift ;;
      --source-repo)
        [ "$CLI_MODE" = validate ] || { usage >&2; die_early "--source-repo is only for validate" 2; }
        [ "$CLI_SOURCE_REPO_SET" = 0 ] || { usage >&2; die_early "--source-repo was given more than once" 2; }
        [ $# -ge 2 ] || { usage >&2; die_early "--source-repo needs a directory" 2; }
        CLI_SOURCE_REPO="$2"; CLI_SOURCE_REPO_SET=1; shift 2 ;;
      --source-repo=*)
        [ "$CLI_MODE" = validate ] || { usage >&2; die_early "--source-repo is only for validate" 2; }
        [ "$CLI_SOURCE_REPO_SET" = 0 ] || { usage >&2; die_early "--source-repo was given more than once" 2; }
        CLI_SOURCE_REPO="${1#--source-repo=}"; CLI_SOURCE_REPO_SET=1; shift ;;
      *) usage >&2; die_early "unknown argument for $CLI_MODE: $1" 2 ;;
    esac
  done
  if [ "$CLI_HOME_SET" = 1 ]; then
    [ "$CLI_HOME" = "/" ] || CLI_HOME="${CLI_HOME%/}"
    valid_home "$CLI_HOME" || die_early "--home needs an absolute path of letters, digits, '.', '_', '-' and '/', outside system directories" 2
  fi
  if [ "$CLI_SOURCE_REPO_SET" = 1 ]; then
    [ "$CLI_SOURCE_REPO" = "/" ] || CLI_SOURCE_REPO="${CLI_SOURCE_REPO%/}"
    valid_home "$CLI_SOURCE_REPO" || die_early "--source-repo needs an absolute path of letters, digits, '.', '_', '-' and '/', outside system directories" 2
  fi
}

parse_args() {
  if [ "${1:-}" = status ] || [ "${1:-}" = validate ]; then
    parse_check_args "$@"
    return 0
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) printf 'Oracle OPS Installer %s (Oracle OPS %s, commit %s)\n' "$INSTALLER_VERSION" "$OPS_VERSION" "$OPS_COMMIT"; exit 0 ;;
      --java-archive)
        [ $# -ge 2 ] || die_early "--java-archive needs a file" 2
        JAVA_ARCHIVE="$2"; shift 2 ;;
      --java-archive=*) JAVA_ARCHIVE="${1#--java-archive=}"; shift ;;
      *) usage >&2; die_early "unknown argument: $1" 2 ;;
    esac
  done
  if [ -n "$JAVA_ARCHIVE" ]; then
    [[ "$JAVA_ARCHIVE" =~ ^/[A-Za-z0-9._/+-]+$ ]] || die_early "--java-archive needs an absolute path of plain characters" 2
    if [ -L "$JAVA_ARCHIVE" ] || [ ! -f "$JAVA_ARCHIVE" ] || [ ! -r "$JAVA_ARCHIVE" ]; then die_early "--java-archive: not a readable regular file" 2; fi
  fi
}

# menu_item <number> <text> [reason it does not apply]
menu_item() {
  if [ -n "${3:-}" ]; then printf '  %2s) %-32s (not available: %s)\n' "$1" "$2" "$3"
  else printf '  %2s) %s\n' "$1" "$2"; fi
}

menu() {
  local c inst=0 keys=0 none="" item name
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then inst=1; describe_installation; fi
  for item in $API_KEY_FILES; do
    name="${item%%:*}"
    if [ -f "$CRED_DIR/$name" ] && [ ! -L "$CRED_DIR/$name" ]; then keys=1; fi
  done
  [ "$inst" = 1 ] || none="nothing installed"
  echo
  say "Oracle OPS Installer $INSTALLER_VERSION"
  say "========================"
  say "Oracle OPS release $OPS_VERSION (commit ${OPS_COMMIT:0:7}). Oracle APEX is not installed or configured by this installer."
  if [ "$inst" = 1 ]; then
    if [ "$INST_ACTIVE" = yes ]; then name="running"; else name="not running"; fi
    say "Installed: Oracle OPS ${INST_RELEASE:-(release unknown)} at ${INST_HOME:-(unknown directory)}, service $name"
  else
    say "Installed: none found on this host"
  fi
  echo
  if [ "$inst" = 1 ]; then menu_item 1 "Fresh Installation" "Oracle OPS is already installed"; else menu_item 1 "Fresh Installation"; fi
  menu_item 2 "Upgrade Existing Installation" "$none"
  menu_item 3 "Reconfigure Installation" "$none"
  menu_item 4 "Validate Environment"
  menu_item 5 "View Installation Status"
  menu_item 6 "View APIs"
  if [ "$keys" = 1 ]; then menu_item 7 "View API Keys"; else menu_item 7 "View API Keys" "no keys in $CRED_DIR"; fi
  menu_item 8 "View Configuration" "$none"
  menu_item 9 "Uninstall Oracle OPS" "$none"
  menu_item 10 "Exit"
  echo
  choose c "Choose an option [1-10]: " 1 2 3 4 5 6 7 8 9 10
  log "menu choice: $c"
  echo
  case "$c" in
    1) op_install ;;
    2) op_upgrade ;;
    3) op_reconfigure ;;
    4) op_validate ;;
    5) op_status ;;
    6) op_view_apis ;;
    7) op_view_api_keys ;;
    8) op_view_config ;;
    9) op_deinstall ;;
    10) finish 0 ;;
  esac
}
