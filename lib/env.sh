#!/bin/bash
# Oracle OPS Installer library: host locations, limits, run state, and the seams tests replace (docs/DEVELOPER.md)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---- Host locations and limits (plain globals; tests reassign them after sourcing) -----------------------------------
STATE_DIR="/var/lib/oracle-ops-installer"   # root-only; per-run staging directories run.XXXXXXXX live here
LOG_DIR="/var/log/oracle-ops-installer"     # root-only protected logs
AUTH_BASE="/run"                            # RAM-backed (tmpfs) home of the short-lived token file, when safe
CRED_DIR="/etc/oracle-ops"                  # Oracle OPS's credential directory: read-only checks here, never written
UNIT_FILE="/etc/systemd/system/oracle-ops.service"
UNIT_NAME="oracle-ops.service"
LOGROTATE_DIR="/etc/logrotate.d"
OS_RELEASE_FILE="/etc/os-release"
SYSTEMD_RUN_DIR="/run/systemd/system"
DEFAULT_HOME="/u01/oracle_ops_runtime"     # Oracle OPS's documented default installation directory
SAFE_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
ADMIN_UID=0
ROOT_HOME="/root"                           # HOME given to the Oracle OPS scripts (main() reads root's entry)
HOME_FORBIDDEN="/ /etc /proc /sys /dev /run /boot /bin /sbin /lib /lib64 /usr /tmp /var/tmp /var/lib/oracle-ops-installer /etc/oracle-ops"
LOG_KEEP=20
CHECK_LOG_KEEP=20                           # check logs (oracle-ops-check-*.log) kept by the menu start-up; the CLI path never prunes
MIN_STAGE_MB=200
GIT_LS_REMOTE_TIMEOUT=120
GIT_CLONE_TIMEOUT=900
PKG_TIMEOUT=1800
JAR_VERSION_ENTRY="com/oracleops/core/version.properties"
SERVICE_LOG_REL="logs/oracle-ops.log"
DB_HEALTHY_LINE="Database connectivity startup health check: HEALTHY"
MARKER_NAME=".oracle-ops-installer-run"
MARKER_TEXT="oracle-ops-installer-run"
# Environment variables passed through to child processes (everything else is removed; see clean_env_exec).
ENV_KEEP="TERM http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
# Tools needed by the installer and by the Oracle OPS scripts it runs (their own preflights check them again).
REQUIRED_TOOLS="git curl unzip tar gzip sha256sum flock setpriv find readlink stat mktemp timeout df awk sed grep install cmp cp chmod chown chgrp mkdir rm mv ln tee env getent systemctl tr cut sort head tail date id uname stty od sleep ip"
BOOTSTRAP_TOOLS="id mkdir chmod stat mktemp date flock rm sed tr dirname basename"

# ---- Read-only checks (status / validate): their own settings, never read from the environment ----------------------------
DEFAULT_SOURCE_REPO="/u01/oracle_ops"       # the local Oracle OPS repository validate reads the pinned commit from
STATUS_LOG_TAIL=2000                        # lines of the service log status examines
CLI_MODE=""                                 # status | validate when the installer was started with that subcommand
CLI_HOME=""                                 # --home given on the command line
CLI_HOME_SET=0
CLI_SOURCE_REPO=""                          # --source-repo given on the command line
CLI_SOURCE_REPO_SET=0
SOURCE_REPO=""                              # the repository validate reads (CLI option, menu answer or the default)
# Credential files status examines by metadata only (never opened): name:owner-kind:mode, owner-kind root = root:<Group>, service = <User>:<Group>.
CRED_FILES="database.credentials:root:640 api.credentials:root:640 api-control.credentials:root:640 apps.credentials:service:400"
# Tools a check needs besides the start-up tools; a missing one makes the items that need it FAIL (they are never skipped).
CHECK_BOOTSTRAP_TOOLS="id mkdir stat date flock sed tr dirname basename"

# ---- REST API keys and the fresh-install questions (0.3.0) ----------------------------------------------------------------
# The two key files Oracle OPS reads (fixed paths in Oracle OPS's ApiTokenLoader): <file>:<property>:<scope>.
API_KEY_FILES="api.credentials:api.token:read api-control.credentials:api.control.token:control"
API_KEY_MIN_CHARS=32                        # ApiTokenLoader.MIN_TOKEN_CHARS; the installer generates 64 hex characters
API_KEY_BYTES=32                            # random bytes per generated key
RANDOM_SOURCE="/dev/urandom"
DEFAULT_API_BIND="127.0.0.1"                # loopback; another address needs the APEX/ORDS client addresses (plain-HTTP exception)
API_CLIENTS_MAX=8                           # Oracle OPS's limit for api.plain-http.client-addresses
API_PORT_MIN=1024                           # the service runs unprivileged: no port below 1024
API_STATUS_PATH="/api/v1/ops/status"        # the route the final validation expects in Oracle OPS's route line
API_ROUTES_LINE="API routes served: ["      # Oracle OPS's start-up line listing the routes it serves
API_DISABLED_LINE="REST API is disabled (api.enabled=false)"
DISK_WARN_MB=1024                           # free space below this on the installation file system is a warning
RESTART_WAIT_SECONDS=90                     # Reconfigure: how long a restarted service may take to report its routes
SHOW_WORD="SHOW"                            # View API Keys: the word the operator types to display a key

# ---- The Oracle OPS repository database (0.3.0) -------------------------------------------------------------------------
# Fixed names: Oracle OPS's code and SQL use exactly these (OPS_OWNER owns the objects, OPS_RUNTIME is the service's login).
DB_OWNER="OPS_OWNER"
DB_RUNTIME="OPS_RUNTIME"
DB_TABLESPACE="OPS_DATA"
DEFAULT_DB_PORT=1521
# The DBA_* views the Oracle OPS scripts read in their checks: the DBA SQL grants SELECT on exactly these to OPS_OWNER, so
# the installer can run those scripts unchanged in an OPS_OWNER session (tests/db-check.py derives the list from the source).
DB_DICTIONARY_VIEWS="DBA_ARGUMENTS DBA_COL_PRIVS DBA_ERRORS DBA_OBJECTS DBA_PROCEDURES DBA_ROLE_PRIVS DBA_SYS_PRIVS DBA_TABLESPACES DBA_TAB_PRIVS DBA_USERS"
DB_LOGIN_TIMEOUT=15                         # seconds for the OPS_OWNER login (JDBC)
DB_TOOL_TIMEOUT=1800                        # hard limit for one run of the database tool (JVM start, checks, all scripts)
DB_TOOL_CLASS="OpsSchemaDeploy"

# ---- State ---------------------------------------------------------------------------------------------------------------
OPERATION="installer run"
STAGE_TOTAL=0
LOG_FILE=""
RUN_DIR=""
AUTH_DIR=""
OPS_SRC=""
TOKEN=""              # NEVER exported, never passed as an argument, never printed or logged
LOCK_FD=""
JAVA_ARCHIVE=""
FAIL_REASON=""
SUCCESS_TEXT=""
CLEANUP_PROBLEMS=""
CAPTURE=""
INST_HOME=""; INST_USER=""; INST_GROUP=""; INST_RELEASE=""; INST_COMMIT=""; INST_ACTIVE=""
TARGET_HOME=""
SVC_USER=""; SVC_GROUP=""; SVC_GID=""      # fresh install: the service account the operator chose
API_BIND=""; API_PORT=""                  # fresh install: the REST API listener
API_KEY_REDACT_1=""; API_KEY_REDACT_2=""  # API keys while they are handled: sanitize_stream removes them from the log
KEYS_CREATED=""; KEYS_KEPT=""             # fresh install: which key files were created / already existed
API_CLIENTS=""                            # fresh install: APEX/ORDS client addresses when API_BIND is not loopback
DB_HOST=""; DB_PORT=""; DB_SERVICE=""     # fresh install: the repository database
OWNER_PW=""                               # the OPS_OWNER password: NEVER exported, never an argument, unset after the database step
DB_STATE=""                               # EMPTY | COMPLETE | PARTIAL, as the database tool reported it

# ---------------------------------------------------------------------------------------------------------------------------
# Seams
# ---------------------------------------------------------------------------------------------------------------------------

is_root() { [ "$(id -u)" -eq 0 ]; }
stdin_is_tty() { [ -t 0 ]; }
host_arch() { uname -m; }
is_tmpfs() { [ "$(stat -f -c %T "$1" 2>/dev/null)" = "tmpfs" ]; }
service_active() { systemctl is-active --quiet "$UNIT_NAME"; }
root_home() { getent passwd root 2>/dev/null | cut -d: -f6; }

# account_uid <user> / group_gid <group>: the numeric id from the account database; empty if there is no such entry.
account_uid() { { getent passwd "$1" 2>/dev/null || true; } | cut -d: -f3; }
group_gid() { { getent group "$1" 2>/dev/null || true; } | cut -d: -f3; }
# port_in_use <address> <port>: something already accepts connections there (a connect only, nothing is sent).
port_in_use() { timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null; }
# memory_total_mb: MemTotal from /proc/meminfo in MB; empty if unreadable.
memory_total_mb() { awk '/^MemTotal:/ { print int($2 / 1024); exit }' /proc/meminfo 2>/dev/null || true; }
# restart_service: Reconfigure only, after new API keys were written and the operator asked for it.
restart_service() { systemctl restart "$UNIT_NAME"; }
# clear_screen: View API Keys, after a key was shown (the screen and, where the terminal supports it, its scroll-back).
clear_screen() { printf '\033[H\033[2J\033[3J'; }
# tcp_open <host> <port>: a TCP connection can be made (the database listener check; nothing is sent).
tcp_open() { timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null; }
# local_addresses: the IP addresses assigned to this host's interfaces, one per line (read-only).
local_addresses() { { ip -o addr show 2>/dev/null || true; } | awk '{ a = $4; sub(/\/.*/, "", a); print a }'; }
# read_secret_line <variable>: one line from the terminal, not echoed. False at end of input.
read_secret_line() {
  local _s
  IFS= read -r -s _s || { echo; return 1; }
  echo
  printf -v "$1" '%s' "$_s"
  _s=""
}
# db_tool_exec <java> <tool arguments...>: the database tool, run as root with the release's private JDK from the run's root-only
# database directory, with no core dump and a scrubbed environment. The OPS_OWNER password, when needed, is on standard input.
db_tool_exec() {
  local java="$1"
  shift
  ( cd "$RUN_DIR/db" || exit 2
    ulimit -c 0
    CHILD_HOME="$RUN_DIR/githome"
    clean_env_exec timeout --foreground "$DB_TOOL_TIMEOUT" "$java" -XX:-UsePerfData -Xmx256m -cp ojdbc8.jar "$DB_TOOL_CLASS.java" "$@" )
}

# service_state: the unit's state, from systemctl is-active and systemctl show (read-only verbs). Prints
#   IS_ACTIVE=<is-active answer>   (empty if systemctl printed none)
# followed by the four properties of show; fails when show fails. A status check uses nothing else of systemctl.
service_state() {
  local act=""
  if act="$(systemctl is-active "$UNIT_NAME" 2>/dev/null)"; then :; fi   # an inactive unit makes is-active exit non-zero
  printf 'IS_ACTIVE=%s\n' "$act"
  systemctl show -p ActiveState -p SubState -p MainPID -p ActiveEnterTimestamp "$UNIT_NAME" 2>/dev/null
}

# proc_owner_exe <pid>: who runs the process and which program, read from /proc (a /proc entry is owned by the process's
# user and group; the exe link names the program). Prints OWNER=<user>:<group> and EXE=<path>; fails if either is unreadable.
proc_owner_exe() {
  local o e
  o="$(stat -c '%U:%G' "/proc/$1" 2>/dev/null)" || return 1
  e="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
  printf 'OWNER=%s\nEXE=%s\n' "$o" "$e"
}

# run_as_repo_owner <repository> <command...>: runs a command with the privileges of the account that owns <repository>/.git
# (its uid and that account's passwd primary group, no supplementary groups), in "/", in a scrubbed environment with
# HOME=/nonexistent, GIT_CONFIG_NOSYSTEM=1 and GIT_NO_REPLACE_OBJECTS=1, so that a repository somebody else can write is never
# read with root's privileges. Only when the owner is the administrative account (root) is the command run directly (still
# in "/" and in the same environment). Fails if the owner or its primary group cannot be determined.
run_as_repo_owner() {
  local repo="$1" uid gid="" pre=()
  shift
  uid="$(stat -c %u "$repo/.git" 2>/dev/null)" || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  if [ "$uid" != "$ADMIN_UID" ]; then
    gid="$(getent passwd "$uid" 2>/dev/null | cut -d: -f4)" || return 1
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    pre=(setpriv --reuid "$uid" --regid "$gid" --clear-groups)
  fi
  ( cd / || exit 1
    CHILD_HOME=/nonexistent
    export GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1
    ENV_KEEP="$ENV_KEEP GIT_CONFIG_NOSYSTEM GIT_NO_REPLACE_OBJECTS"
    clean_env_exec ${pre[@]+"${pre[@]}"} "$@" )
}
