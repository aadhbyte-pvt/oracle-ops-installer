#!/bin/bash
# Oracle OPS Installer library: prerequisites
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---------------------------------------------------------------------------------------------------------------------------
# Prerequisites (derived from the Oracle OPS scripts' own preflight lists; docs/DEVELOPER.md)
# ---------------------------------------------------------------------------------------------------------------------------

tool_package() {
  case "$1" in
    git|curl|unzip|tar|gzip|sed|grep) echo "$1" ;;
    flock|setpriv) echo util-linux ;;
    find) echo findutils ;;
    ip) echo iproute ;;
    awk) echo gawk ;;
    cmp) echo diffutils ;;
    getent) echo glibc-common ;;
    sha256sum|readlink|stat|mktemp|timeout|df|install|cp|chmod|chown|chgrp|mkdir|rm|mv|ln|tee|env|tr|cut|sort|head|tail|date|id|uname|stty|od|sleep) echo coreutils ;;
    *) echo "" ;;
  esac
}

MISSING_PKGS=""
MISSING_DESC=""
UNFIXABLE=""
scan_prerequisites() {
  local t p platform avail
  MISSING_PKGS=""; MISSING_DESC=""; UNFIXABLE=""
  platform="$(host_platform)"
  in_list "$platform" "$SUPPORTED_PLATFORMS" || UNFIXABLE="$UNFIXABLE"$'\n'"      - operating system $platform is not supported (supported: Oracle Linux 7)"
  [ "$(host_arch)" = "$SUPPORTED_ARCH" ] || UNFIXABLE="$UNFIXABLE"$'\n'"      - processor architecture $(host_arch) is not supported (supported: $SUPPORTED_ARCH)"
  [ -d "$SYSTEMD_RUN_DIR" ] || UNFIXABLE="$UNFIXABLE"$'\n'"      - systemd is not running (Oracle OPS runs as a systemd service)"
  for t in $REQUIRED_TOOLS; do
    command -v "$t" >/dev/null 2>&1 && continue
    p="$(tool_package "$t")"
    if [ -z "$p" ]; then
      UNFIXABLE="$UNFIXABLE"$'\n'"      - $t is missing and cannot be installed by this installer"
    else
      in_list "$p" "$MISSING_PKGS" || MISSING_PKGS="$MISSING_PKGS $p"
      MISSING_DESC="$MISSING_DESC"$'\n'"      - $t (package $p)"
    fi
  done
  if [ ! -d "$LOGROTATE_DIR" ]; then
    in_list logrotate "$MISSING_PKGS" || MISSING_PKGS="$MISSING_PKGS logrotate"
    MISSING_DESC="$MISSING_DESC"$'\n'"      - logrotate (package logrotate)"
  fi
  avail="$(df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR==2 { print int($4 / 1024) }')"
  if [ -n "$avail" ] && [ "$avail" -lt "$MIN_STAGE_MB" ]; then
    UNFIXABLE="$UNFIXABLE"$'\n'"      - only ${avail} MB free for the temporary download in $STATE_DIR (${MIN_STAGE_MB} MB needed)"
  fi
  MISSING_PKGS="${MISSING_PKGS# }"
  log "prerequisites: platform=$platform arch=$(host_arch) missing_packages='${MISSING_PKGS}' unfixable='${UNFIXABLE//$'\n'/ }'"
}

check_prerequisites() {
  local c p
  scan_prerequisites
  if [ -n "$UNFIXABLE" ]; then
    say "      This system does not meet the requirements of Oracle OPS:$UNFIXABLE"
    finish 3 "unsupported system or missing requirement that the installer cannot provide"
  fi
  [ -n "$MISSING_PKGS" ] || { log "prerequisites: all present"; return 0; }
  for p in $MISSING_PKGS; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || finish 1 "internal error: invalid package name"
  done
  say "      Missing prerequisites:$MISSING_DESC"
  if command -v yum >/dev/null 2>&1; then
    say "      1) Install them now with yum"
    say "      2) I will install them myself"
    choose c "      Choose 1 or 2: " 1 2
  else
    c=2
  fi
  if [ "$c" = 2 ]; then
    say "      Install the missing packages as root, then run the installer again:"
    say "        yum install -y $MISSING_PKGS"
    finish 3 "missing prerequisites ($MISSING_PKGS) — manual installation chosen"
  fi
  say "      Installing: $MISSING_PKGS"
  # shellcheck disable=SC2086  # deliberate word splitting: validated, fixed package names
  run_quiet "yum -y install $MISSING_PKGS" pkg_run $MISSING_PKGS || finish 3 "the package manager could not install: $MISSING_PKGS"
  scan_prerequisites
  if [ -n "$MISSING_PKGS" ] || [ -n "$UNFIXABLE" ]; then
    finish 3 "prerequisites still missing after the installation attempt: ${MISSING_PKGS:-see log}"
  fi
  log "prerequisites: all present after installation"
}
