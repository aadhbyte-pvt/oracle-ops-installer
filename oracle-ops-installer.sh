#!/bin/bash
# Oracle OPS Installer
#
# An interactive, menu-driven installer for Oracle OPS. The operator clones this repository and runs it as root.
# It contains no Oracle OPS code and none of Oracle OPS's installation logic: for each changing action it downloads ONE
# pinned, verified Oracle OPS release from the private repository into a root-only staging directory, runs the Oracle OPS
# script made for that action, verifies the result, and removes the staged source and the access token again. The one
# thing it writes itself is the pair of REST API key files (lib/api-keys.sh). Oracle APEX is out of scope: this installer
# never installs, configures or deploys anything APEX-related (it shows what the APEX Web Credentials need).
#
#   Menu                              What runs
#    1 Fresh Installation             read-only discovery, questions, review; then both API keys in /etc/oracle-ops and
#                                     deploy/scripts/deploy-oracle-ops.sh --home --user --group --enable-api ...
#    2 Upgrade Existing Installation  deploy/scripts/install-release.sh --home --user --group service/ (or activate-release.sh)
#    3 Reconfigure Installation       deploy/scripts/manage-app-credentials.sh (WebLogic), DB password guidance, or new API keys
#    4 Validate Environment           read-only (below)
#    5 View Installation Status       read-only (below)
#    6 View APIs                      read-only: the API catalogue of the pinned release + what the service reports it serves
#    7 View API Keys                  shows a key from /etc/oracle-ops after a typed confirmation; never logged
#    8 View Configuration             read-only: application.yaml (secret-looking values masked), credential file metadata
#    9 Uninstall Oracle OPS           deploy/scripts/service-identity.sh retire --home <dir> --apply (renames, deletes nothing)
#
# Read-only checks (menu 5 Status, 4 Validate; or from the command line, root, no terminal, nothing is changed):
#   Status                 examines the installed Oracle OPS (unit, release, build commit, runtime, service, log, file metadata)
#   Validate               status, then deploy/scripts/config-migrate.sh validate and service-identity.sh check, run from a
#                          verified copy of exactly six files taken from the local Oracle OPS repository (git archive of the
#                          pinned commit; each file's SHA-256 must equal OPS_FILE_MANIFEST below)
#
# Usage:   sudo bash oracle-ops-installer.sh [--java-archive FILE]
#          sudo bash oracle-ops-installer.sh status   [--home DIR]
#          sudo bash oracle-ops-installer.sh validate [--home DIR] [--source-repo DIR]
#          bash oracle-ops-installer.sh --help | --version
#
# Exit status: 0 done, or nothing to do, or no problem found | 1 the action failed, or a check failed | 2 cannot run as
#              invoked | 3 prerequisites missing | 4 source access or verification failed (also: validate cannot verify the
#              pinned source) | 5 cancelled by the operator | 6 the action does not apply to this host (nothing changed; for
#              status/validate: Oracle OPS is not installed) | 129/130/143 interrupted
#
# Layout: this entry script holds the version, the pinned Oracle OPS release, the library manifest, the loader and main().
# Everything else lives in lib/*.sh, which the loader verifies (SHA-256 per file; ownership of the whole path when run as
# root) before it sources anything: see "Library loader" below and docs/DEVELOPER.md. This file is also sourced by the test
# suite (tests/); everything runs from main(). Functions marked "seam" (lib/env.sh) wrap host-specific actions so tests can
# replace them, and the "Host locations" globals (lib/env.sh) are reassigned by the tests after sourcing (they are NOT read
# from the environment).

set +x +v   # never trace: a trace would print the access token the moment it is handled

INSTALLER_VERSION="0.3.1"

# ---- Pinned Oracle OPS release. Changed only by a reviewed installer release (docs/DEVELOPER.md). ----------------------
OPS_REPO_URL="https://github.com/Moon2998/oracle-ops.git"
OPS_COMMIT="3299d8e33116c2d9b0387285e47f4fb6067cf52c"   # full commit id; nothing else is ever checked out
OPS_VERSION="0.1.10"                                     # service/VERSION at OPS_COMMIT
SUPPORTED_PLATFORMS="ol:7"                               # /etc/os-release ID:major; must be in the release's jdk.platforms
SUPPORTED_ARCH="x86_64"
# git's credential prompts for OPS_REPO_URL, answered by the temporary askpass helper (and nothing else is answered).
GIT_HOST_URL="https://github.com"
GIT_USERNAME="x-access-token"
GIT_PASSWORD_URL="https://x-access-token@github.com"

# ---- Oracle OPS file manifest (R1): the trust anchor of "validate" ---------------------------------------------------------
# SHA-256 and path of every file validate takes out of the local Oracle OPS repository (git archive of OPS_COMMIT) and then runs
# or reads: exactly these six files, nothing else is extracted. They are the blobs at OPS_COMMIT. Changed together with the pin by
# a reviewed installer release (docs/DEVELOPER.md, "Moving the pin"): the digest is `git show <commit>:<path> | sha256sum`.
OPS_FILE_MANIFEST=(
  "4205c252ec5fca4aa289d6cf72374a321510cefbbb14a9b266f92b02ce413ed9  deploy/scripts/config-migrate.sh"
  "adb79693c16154bcb40126f91869540545e9453995b58375b60889633c35ae4e  deploy/scripts/service-identity.sh"
  "956121fda5804cc2ad1d54464103acd980ce7318401b279a3789815640911517  deploy/scripts/ownership-lib.sh"
  "2c1009dcfcef35d51e4a574b40d31441fe823bfe1ef8337e29f17bb4de674d85  deploy/scripts/provision-java.sh"
  "fa5e69025690abaa746781dbb858a488842cc37fc54e970de786a0f0f2678c23  deploy/java-runtime.properties"
  "fecf23c4b3c2c29381d4c14cacb998939eb53f5791b99ab7e4e0bc7972c44524  service/VERSION"
)

# ---- Oracle OPS database scripts: run in this order AS OPS_OWNER by Fresh Installation (lib/db-deploy.sh) ------------------
# "<SHA-256 of the blob at OPS_COMMIT>  <run|include|grant>  <path in the release | package for an installer grant>".
# run = executed; include = only reached through @@ from the script before it (copied beside it); grant = the one statement
# the release has no script for: GRANT EXECUTE ON OPS_OWNER.<package> TO OPS_RUNTIME (V5_001 requires it). Changed together
# with the pin; tests/db-check.py compares every digest with the pinned commit.
OPS_DB_SCRIPTS=(
  "dc3b0c2c6d396037421e57cf7d9b4f0acf11cc61cd5ef66d0f6751d7d55a76c5  run  db/migrations/V4_001__create_ops_run.sql"
  "07d93decc0af51f9fbbb1c19aed87e42d521fa183ffbe5ac1846d67f88c5a5d6  run  db/migrations/V4_002__create_ops_run_api.sql"
  "-  grant  ops_run_api"
  "dd578b42cc4089474ccded2e17a3c9afde7bef15c580ab6b05f6edd225bdb52a  run  db/migrations/V5_001__add_ops_run_get_run.sql"
  "668650d4e82a098c99e3261799dbace26afb5b7b44be1b50f335f2c3596ef218  run  docs/12-ddl/V8_001__create_ops_wls_action.sql"
  "2f9c9d85ecc4e50b3f12bb00dbf1f3101824e759cdaa3af186b93f9508f6b6f1  include  docs/12-ddl/V8_001__ops_wls_action_api_body.sql"
)

# ---- Library manifest: SHA-256 of every library the loader will source, in loading order. -----------------------------
# Regenerated by tests/update-lib-digests.sh (tests/run-tests.sh fails while it is stale); never edit a digest by hand.
# BEGIN LIB MANIFEST
LIB_MANIFEST=(
  "74b4566bc18e93c3e2ea538629f13fa29284d2b7be5eb6e017376b0175e5e7ed  lib/env.sh"
  "72e0994e9cad2cd630cef212638cd2a81c04b6dce47843e110038f76bd515293  lib/common.sh"
  "7d16efd143248f07ff29a3e233afde2d6138a8e4f0962e69430d99a6a3775d5a  lib/state.sh"
  "bef89409c45b5f23d264eb70d4a1f0ad7ae211c7d4e4c5288c46ca9dd7f096cc  lib/prereq.sh"
  "cd13c3ceaf025e7b588db06cfc49c09c2387856252830575a17465cd61fb1f4d  lib/installation.sh"
  "a4b6b957711f0dc58f120864638d71e09c2b454eaf19ed54ad1d78d8e48ec941  lib/source.sh"
  "26092336d1610412984c55fa4569de3d9001159171adba69d8a732c3ca78cffa  lib/discover.sh"
  "5ac6b32a6834eeedb1d3e2d2484a0069800e1a915435aa128e00e755edba0c06  lib/api-keys.sh"
  "e45ec2894f8649b3da028b21b9b2dd324a9abbe8704fc1589dc590f5de3bb47f  lib/api-catalogue.sh"
  "1346801899a84fd7062acfdb306d124f10bcb8d630e6b88f183ad96baa658c25  lib/db-tool.sh"
  "17435eed0a8d10406638c6e6f3a72b5ec3ab5b890d308e6f87d2381384409450  lib/db-deploy.sh"
  "9f39d7fe574f19263d3129535063b4f41d180a484c2f9dfe054b9b5992cd2e55  lib/ops-install.sh"
  "f9d672108166958b5dbb7dab4d03adc3c0a952adeb0818bfc62d0fd470d39e71  lib/ops-upgrade.sh"
  "fd17695ed722df47dc555a5123725c3ead4eacd7d6a40691ebab5d3bb8dbc1c5  lib/ops-deinstall.sh"
  "16968d75e23f7c223750c780e899db88277794bb24cc87a434aaea039917c0a2  lib/ops-credentials.sh"
  "14308d89bbd18b2b0564dbb1a5f1db8d36c77ad7866776739a00f8ef3a920794  lib/ops-views.sh"
  "45ee4226ce47482e088bcb07b9f76ddfc9049cecebe88aebd8d1c313000d06a5  lib/check-startup.sh"
  "9c929e38522221cad99c24727e53de351fe5ea1b30dc165c7b174fae2f8f07dd  lib/ops-status.sh"
  "1a09e62a09f12ad8a51db286f622886cd5d14f544f4f0926c16642e33fab4861  lib/ops-validate.sh"
  "412b9a33ca4f7937b626968bca2021853233b94be72afff59f0ffb4439af9b89  lib/menu.sh"
)
# END LIB MANIFEST

# ---- Library loader ---------------------------------------------------------------------------------------------------------
# Runs before any library exists, so it uses only constants defined in this file and absolute tool paths (never PATH).
#  * Executed as root: the whole path (this file, lib/, every listed library, every directory up to /) must be owned by
#    uid 0 and not writable by group or other (a sticky directory is accepted only when the next path component is root-owned)
#    BEFORE anything is hashed. Executed as another user the ownership step is skipped (that user cannot gain privileges, and
#    the installer refuses to act unless root), so --help and --version work from a checkout.
#  * Every listed library must exist, be a regular file (not a symbolic link) and match its digest; only then is any of them
#    sourced. Files in lib/ that are not listed are never sourced.
#  * Sourced (the test suite): the libraries are verified and sourced at load; main() then runs the ownership check against
#    ADMIN_UID (see ldr_check_sourced_install).
#  * Executed as root from an UNPROTECTED path (for example a clone in a directory owned by the oracle account), 0.3.0 no
#    longer just refuses: it explains the risk, and after a typed "yes" on a terminal copies the entry script and the listed
#    libraries into a new root-only directory (LOADER_COPY_BASE/oracle-ops-installer-copy.XXXXXXXX, 0700), runs the copy as a
#    child (whose own loader verifies the whole path and every digest again), removes the copy and exits with the child's
#    status. The copy protects the run against changes made WHILE it runs; it cannot prove that nobody changed the files
#    before (README "Download and run": compare the entry script's SHA-256 with the published one).
# Any failure prints a message on stderr and returns 2 (sourced) or exits 2 (executed); no library code has run.
LOADER_ADMIN_UID=0
LOADER_COPY_BASE="/var/lib"
# Test seam: treat standard input as a terminal for the copy question. Reset here, so the environment cannot preset it.
LOADER_ASSUME_TTY=""
# Test seam: an owner accepted besides root by the ownership check. Always empty in a real run (reset here, so the environment
# cannot preset it); tests/lib.sh and the integrity tests set it after sourcing, in a subshell.
LOADER_TEST_UID=""
LOADER_EXECUTED=0
LOADER_ENTRY_FILE=""
LOADER_ENTRY_DIR=""
LOADER_STAT=""
LOADER_READLINK=""
LOADER_SHA256=""

ldr_fail() { printf 'Oracle OPS Installer: %s\n' "$1" >&2; }

# ldr_find_tool <variable> <tool>: absolute path of a system tool (/usr/bin, then /bin); false if there is none.
ldr_find_tool() {
  local _ld_d
  for _ld_d in /usr/bin /bin; do
    if [ -f "$_ld_d/$2" ] && [ -x "$_ld_d/$2" ]; then printf -v "$1" '%s' "$_ld_d/$2"; return 0; fi
  done
  return 1
}

# ldr_stat <path>: sets LDR_UID and LDR_MODE (octal permission bits, special bits included) of the path itself (a link is
# not followed); false if it cannot be examined.
ldr_stat() {
  local _ld_out
  _ld_out="$("$LOADER_STAT" -c '%u %a' -- "$1" 2>/dev/null)" || return 1
  LDR_UID="${_ld_out% *}"; LDR_MODE="${_ld_out#* }"
  [[ "$LDR_UID" =~ ^[0-9]+$ ]] && [[ "$LDR_MODE" =~ ^[0-7]{3,4}$ ]]
}

# ldr_owner_ok <uid> <extra uid or empty>: the owner is the loader's administrative account (root), or the extra account.
ldr_owner_ok() { [ "$1" = "$LOADER_ADMIN_UID" ] || { [ -n "$2" ] && [ "$1" = "$2" ]; }; }

# ldr_check_node <path> <extra uid> <next component or empty>: owned by root (or the extra account) and not writable by group
# or other. A sticky directory that is writable is accepted only when <next component> is owned like that too.
ldr_check_node() {
  local _ld_p="$1" _ld_x="$2" _ld_next="$3" _ld_m
  ldr_stat "$_ld_p" || { ldr_fail "cannot examine $_ld_p"; return 1; }
  ldr_owner_ok "$LDR_UID" "$_ld_x" || { ldr_fail "$_ld_p is not owned by an administrative account (owner uid $LDR_UID)"; return 1; }
  _ld_m=$((8#$LDR_MODE))
  [ $((_ld_m & 8#022)) -ne 0 ] || return 0
  if [ -d "$_ld_p" ] && [ ! -L "$_ld_p" ] && [ $((_ld_m & 8#1000)) -ne 0 ] && [ -n "$_ld_next" ]; then
    ldr_stat "$_ld_next" || { ldr_fail "cannot examine $_ld_next"; return 1; }
    if ldr_owner_ok "$LDR_UID" "$_ld_x"; then return 0; fi
    ldr_fail "$_ld_p is a sticky directory writable by other users and its next path component $_ld_next is not owned by an administrative account (owner uid $LDR_UID)"
    return 1
  fi
  ldr_fail "$_ld_p is writable by group or other users (mode $LDR_MODE)"
  return 1
}

# ldr_check_secure <real entry directory> <entry file> <extra owner uid or empty>: the secure-path check described above,
# outermost directory first. Each listed library is examined; a library that is missing is reported by the digest step.
ldr_check_secure() {
  local _ld_dir="$1" _ld_entry="$2" _ld_x="$3" _ld_chain=() _ld_p _ld_i _ld_next _ld_item _ld_rel
  [ ! -L "$_ld_entry" ] || { ldr_fail "$_ld_entry is a symbolic link"; return 1; }
  _ld_p="$_ld_dir"
  while :; do
    _ld_chain+=("$_ld_p")
    [ "$_ld_p" != "/" ] || break
    _ld_p="${_ld_p%/*}"; _ld_p="${_ld_p:-/}"
  done
  for (( _ld_i=${#_ld_chain[@]} - 1; _ld_i >= 0; _ld_i-- )); do
    if [ "$_ld_i" -gt 0 ]; then _ld_next="${_ld_chain[$((_ld_i - 1))]}"; else _ld_next="$_ld_entry"; fi
    ldr_check_node "${_ld_chain[$_ld_i]}" "$_ld_x" "$_ld_next" || return 1
  done
  ldr_check_node "$_ld_entry" "$_ld_x" "" || return 1
  [ ! -L "$_ld_dir/lib" ] || { ldr_fail "$_ld_dir/lib is a symbolic link"; return 1; }
  ldr_check_node "$_ld_dir/lib" "$_ld_x" "" || return 1
  for _ld_item in "${LIB_MANIFEST[@]}"; do
    _ld_rel="${_ld_item#*  }"
    [ ! -L "$_ld_dir/$_ld_rel" ] || { ldr_fail "$_ld_dir/$_ld_rel is a symbolic link"; return 1; }
    [ -e "$_ld_dir/$_ld_rel" ] || continue
    ldr_check_node "$_ld_dir/$_ld_rel" "$_ld_x" "" || return 1
  done
}

# ldr_copy_and_run <arguments of the run...>: the unprotected-path case described above. Returns 2 when the operator does not
# confirm or the copy cannot be made; otherwise it EXITS with the status of the copied installer.
ldr_copy_and_run() {
  local _ld_a _ld_copy _ld_item _ld_rel _ld_rc=0 _ld_mktemp _ld_cp _ld_mkdir _ld_chmod _ld_rm
  ldr_find_tool _ld_mktemp mktemp && ldr_find_tool _ld_cp cp && ldr_find_tool _ld_mkdir mkdir \
    && ldr_find_tool _ld_chmod chmod && ldr_find_tool _ld_rm rm || { ldr_fail "mktemp, cp, mkdir, chmod and rm are required in /usr/bin or /bin"; return 2; }
  {
    printf '\nThe installer files in %s can be changed by an account other than root.\n' "$LOADER_ENTRY_DIR"
    printf 'Anyone with that account could have changed what root is about to run. Continue only if you trust it\n'
    printf '(compare: sha256sum %s  with the value published for this release).\n' "$LOADER_ENTRY_FILE"
    printf 'The installer can copy itself into a new root-only directory under %s and run from there,\n' "$LOADER_COPY_BASE"
    printf 'so nothing can change it during the run. The copy is removed at the end.\n'
  } >&2
  if [ -z "$LOADER_ASSUME_TTY" ] && [ ! -t 0 ]; then
    ldr_fail "no terminal to confirm that: run it from a terminal, or from a root-owned directory (README, \"Download and run\")"
    return 2
  fi
  printf 'Copy the installer and continue? Type "yes": ' >&2
  IFS= read -r _ld_a || _ld_a=""
  [ "$_ld_a" = "yes" ] || { ldr_fail "not confirmed; nothing was run"; return 2; }
  _ld_copy="$(umask 077; "$_ld_mktemp" -d "$LOADER_COPY_BASE/oracle-ops-installer-copy.XXXXXXXX")" \
    || { ldr_fail "cannot create a copy directory in $LOADER_COPY_BASE"; return 2; }
  if ! ( umask 077
         "$_ld_cp" -- "$LOADER_ENTRY_FILE" "$_ld_copy/oracle-ops-installer.sh" && "$_ld_mkdir" -m 0700 -- "$_ld_copy/lib" || exit 1
         for _ld_item in "${LIB_MANIFEST[@]}"; do
           _ld_rel="${_ld_item#*  }"
           [ -f "$LOADER_ENTRY_DIR/$_ld_rel" ] && [ ! -L "$LOADER_ENTRY_DIR/$_ld_rel" ] || exit 1
           "$_ld_cp" -- "$LOADER_ENTRY_DIR/$_ld_rel" "$_ld_copy/$_ld_rel" || exit 1
         done
         "$_ld_chmod" 0700 -- "$_ld_copy" ); then
    "$_ld_rm" -rf --one-file-system -- "$_ld_copy"
    ldr_fail "the installer could not be copied (a listed library is missing or not a regular file)"
    return 2
  fi
  printf 'Running the copy in %s\n\n' "$_ld_copy" >&2
  trap ':' INT TERM HUP     # the copy handles the interrupt; this process only waits for it and cleans up
  "${BASH:-/bin/bash}" "$_ld_copy/oracle-ops-installer.sh" "$@" || _ld_rc=$?
  trap - INT TERM HUP
  "$_ld_rm" -rf --one-file-system -- "$_ld_copy" || printf 'Warning: could not remove %s\n' "$_ld_copy" >&2
  exit "$_ld_rc"
}

# ldr_run <entry script path> <1 if executed, 0 if sourced> <effective uid> [run arguments...]: the whole loader; returns 2 on
# any failure.
ldr_run() {
  local _ld_src="$1" _ld_exec="$2" _ld_euid="$3" _ld_dir _ld_item _ld_digest _ld_rel _ld_file _ld_got _ld_files=()
  shift 3
  if [ -z "$_ld_src" ]; then
    ldr_fail "cannot locate the installer's own files: the script name is empty (run it from a file, not from standard input)"
    return 2
  fi
  ldr_find_tool LOADER_STAT stat && ldr_find_tool LOADER_READLINK readlink && ldr_find_tool LOADER_SHA256 sha256sum \
    || { ldr_fail "stat, readlink and sha256sum are required in /usr/bin or /bin"; return 2; }
  _ld_dir="${_ld_src%/*}"
  if [ "$_ld_dir" = "$_ld_src" ]; then _ld_dir="."; else _ld_dir="${_ld_dir:-/}"; fi
  _ld_dir="$("$LOADER_READLINK" -f -- "$_ld_dir" 2>/dev/null)" && [ -d "$_ld_dir" ] \
    || { ldr_fail "cannot resolve the directory of $_ld_src"; return 2; }
  LOADER_EXECUTED="$_ld_exec"
  LOADER_ENTRY_DIR="$_ld_dir"
  LOADER_ENTRY_FILE="$_ld_dir/${_ld_src##*/}"
  if [ "$_ld_exec" = 1 ] && [ "$_ld_euid" = "$LOADER_ADMIN_UID" ]; then
    ldr_check_secure "$LOADER_ENTRY_DIR" "$LOADER_ENTRY_FILE" "$LOADER_TEST_UID" || ldr_copy_and_run "$@" || return 2
  fi
  [ "${#LIB_MANIFEST[@]}" -gt 0 ] || { ldr_fail "the library manifest is empty"; return 2; }
  for _ld_item in "${LIB_MANIFEST[@]}"; do
    _ld_digest="${_ld_item%%  *}"; _ld_rel="${_ld_item#*  }"
    if [[ ! "$_ld_digest" =~ ^[0-9a-f]{64}$ ]] || [[ ! "$_ld_rel" =~ ^lib/[a-z0-9-]+\.sh$ ]]; then
      ldr_fail "the library manifest is malformed: $_ld_item"; return 2
    fi
    _ld_file="$_ld_dir/$_ld_rel"
    if [ -L "$_ld_file" ]; then ldr_fail "$_ld_rel is a symbolic link"; return 2; fi
    if [ ! -f "$_ld_file" ]; then ldr_fail "$_ld_rel is missing or not a regular file"; return 2; fi
    _ld_got="$("$LOADER_SHA256" -- "$_ld_file" 2>/dev/null)" || { ldr_fail "cannot read $_ld_rel"; return 2; }
    _ld_got="${_ld_got%% *}"
    if [ "$_ld_got" != "$_ld_digest" ]; then ldr_fail "$_ld_rel does not match its recorded SHA-256 digest"; return 2; fi
    _ld_files+=("$_ld_file")
  done
  for _ld_file in "${_ld_files[@]}"; do
    # shellcheck source=/dev/null
    . "$_ld_file"
  done
}

# Sourced only (the test suite): main() calls this first; the same ownership check as for a root run, against ADMIN_UID
# (after the tests reassign it). An executed run was checked (root) or deliberately not (other users) by the loader.
ldr_check_sourced_install() {
  [ "$LOADER_EXECUTED" != 1 ] || return 0
  ldr_check_secure "$LOADER_ENTRY_DIR" "$LOADER_ENTRY_FILE" "${LOADER_TEST_UID:-$ADMIN_UID}" || exit 2
}

# ---------------------------------------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------------------------------------

main() {
  ldr_check_sourced_install
  set -euo pipefail
  set +x +v
  umask 077
  scrub_environment
  parse_args "$@"
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    die_early "bash 4.2 or later is required" 2
  fi
  is_root || die_early "run the installer as root, for example:  sudo bash $0" 2
  [ -z "$CLI_MODE" ] || check_main "$CLI_MODE"   # status / validate: the strict read-only path; never returns
  stdin_is_tty || die_early "the installer is interactive; run it from a terminal" 2
  local t missing=""
  for t in $BOOTSTRAP_TOOLS; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || die_early "basic system tools are missing:$missing" 3
  ROOT_HOME="$(root_home)"; ROOT_HOME="${ROOT_HOME:-/root}"
  export HOME="$ROOT_HOME"
  init_logging
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  init_state
  prune_check_logs
  menu
}

[ "${BASH_SOURCE[0]:-}" != "$0" ] || LOADER_EXECUTED=1
ldr_run "${BASH_SOURCE[0]:-}" "$LOADER_EXECUTED" "$EUID" "$@" || { return 2 2>/dev/null || exit 2; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
