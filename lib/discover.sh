#!/bin/bash
# Oracle OPS Installer library: read-only environment discovery for Fresh Installation (0.3.0)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# READ-ONLY: every function here only reads (os-release, uname, /proc/meminfo, df, getent, stat, find). Nothing is created,
# changed, started or removed; tests/installer-test.sh compares the sandbox before and after a discovery to prove it.

DISCOVER_WARNINGS=0

# disc_line <label> <text>: one aligned line of the discovery report, on the terminal and in the log.
disc_line() {
  printf '      %-22s %s\n' "$1" "$2"
  log "discovery: $1: $2"
}

# nearest_existing_dir <path>: <path> itself if it is a directory, else its closest existing parent directory.
nearest_existing_dir() {
  local p="$1"
  while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -d "$p" ]; do p="${p%/*}"; done
  printf '%s' "${p:-/}"
}

# free_mb <directory>: free space for unprivileged users on the file system of <directory>, in MB; empty if unknown.
free_mb() { { df -Pk "$1" 2>/dev/null || true; } | awk 'NR==2 { print int($4 / 1024) }'; }

os_pretty_name() {
  local n=""
  [ -r "$OS_RELEASE_FILE" ] && n="$(sed -n 's/^PRETTY_NAME=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d '"'"'")"
  printf '%s' "${n:-unknown}"
}

# discover_report: what is on this host, before any question is asked. Never changes anything.
discover_report() {
  local platform arch mem d free entries e retired=""
  DISCOVER_WARNINGS=0
  platform="$(host_platform)"; arch="$(host_arch)"
  if in_list "$platform" "$SUPPORTED_PLATFORMS"; then
    disc_line "Operating system" "$(os_pretty_name) ($platform) - supported"
  else
    disc_line "Operating system" "$(os_pretty_name) ($platform) - NOT supported (supported: $SUPPORTED_PLATFORMS)"
  fi
  if [ "$arch" = "$SUPPORTED_ARCH" ]; then disc_line "CPU architecture" "$arch - supported"
  else disc_line "CPU architecture" "$arch - NOT supported (supported: $SUPPORTED_ARCH)"; fi
  mem="$(memory_total_mb)"
  disc_line "Memory" "${mem:-unknown} MB total"
  if [ -d "$SYSTEMD_RUN_DIR" ]; then disc_line "systemd" "running"; else disc_line "systemd" "NOT running"; fi
  disc_line "Required tools" "present (checked above)"
  disc_line "Java" "not needed on the host: Oracle OPS installs its own pinned private JDK"
  d="$(nearest_existing_dir "$DEFAULT_HOME")"
  free="$(free_mb "$d")"
  disc_line "Disk free" "${free:-unknown} MB on the file system of $d (default installation directory)"
  if [ -n "$free" ] && [ "$free" -lt "$DISK_WARN_MB" ]; then
    DISCOVER_WARNINGS=$((DISCOVER_WARNINGS + 1))
    disc_line "" "WARNING: less than $DISK_WARN_MB MB free there"
  fi
  if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
    disc_line "Oracle OPS service" "$UNIT_NAME is defined (an installation exists)"
  else
    disc_line "Oracle OPS service" "not defined"
  fi
  if [ -L "$CRED_DIR" ]; then
    DISCOVER_WARNINGS=$((DISCOVER_WARNINGS + 1))
    disc_line "Credential directory" "WARNING: $CRED_DIR is a symbolic link"
  elif [ -d "$CRED_DIR" ]; then
    entries=""
    while IFS= read -r e; do entries="$entries $e"; done < <(find "$CRED_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)
    if [ -n "$entries" ]; then disc_line "Credential directory" "$CRED_DIR exists, holds:$entries"
    else disc_line "Credential directory" "$CRED_DIR exists (empty)"; fi
  else
    disc_line "Credential directory" "$CRED_DIR does not exist yet"
  fi
  while IFS= read -r e; do retired="$retired $e"; done < <(find "$(dirname "$DEFAULT_HOME")" -mindepth 1 -maxdepth 1 \
    -name "$(basename "$DEFAULT_HOME").retired-*" -printf '%f\n' 2>/dev/null | sort)
  [ -z "$retired" ] || disc_line "Earlier installations" "renamed by De-install:$retired (kept, not used)"
  return 0
}

# disk_check_home <home>: free space where <home> will be created; a warning only (the Oracle OPS pre-check is binding).
disk_check_home() {
  local d free
  d="$(nearest_existing_dir "$1")"
  free="$(free_mb "$d")"
  log "installation directory $1: ${free:-unknown} MB free on the file system of $d"
  if [ -n "$free" ] && [ "$free" -lt "$DISK_WARN_MB" ]; then
    say "      WARNING: only $free MB free on the file system of $d. The Oracle OPS pre-check decides whether that is enough."
  fi
  return 0
}
