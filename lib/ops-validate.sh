#!/bin/bash
# Oracle OPS Installer library: action: validate (read-only)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# validate = every status item, then the checks of the PINNED Oracle OPS release, run from a verified copy of exactly six files
# taken out of the local Oracle OPS repository with git archive of the pinned commit (never the working tree, no network):
#   1. the repository is a real directory with a real .git, without attributes, grafts or replace refs (which could change what
#      git archive produces);
#   2. git runs only through the seam run_as_repo_owner (the privileges of the repository's owner, never root's, unless the
#      owner is root): rev-parse --verify of the pin, and archive of exactly the manifest paths, written by root to src.tar;
#   3. the archive is listed (regular files and directories only, relative names without ..), extracted by root with
#      --no-same-owner --no-same-permissions into RUN_DIR/src, and the extracted regular files must be EXACTLY the manifest set,
#      each with the SHA-256 recorded in OPS_FILE_MANIFEST (the root-held trust anchor, next to the pin in the entry script), and
#      service/VERSION must equal OPS_VERSION;
#   4. only then are config-migrate.sh validate and service-identity.sh check run, through validate_ops_run (ops_run with the
#      working directory RUN_DIR). config-migrate.sh's Java tool opens the token files itself to check them and prints no value
#      (documented side effect R3); the installer itself never opens a credential file.
# Any failure of 1 to 3 ends with exit status 4 and nothing of the release is run. The run directory is removed on every path.

VALIDATE_SOURCE_FAILED=0

# validate_manifest_paths: fills VALIDATE_PATHS from OPS_FILE_MANIFEST; false (and a problem noted) if the manifest is malformed.
validate_manifest_paths() {
  local item digest rel
  VALIDATE_PATHS=()
  if [ "${#OPS_FILE_MANIFEST[@]}" -eq 0 ]; then item_fail "the installer's Oracle OPS file manifest is empty"; return 1; fi
  for item in "${OPS_FILE_MANIFEST[@]}"; do
    digest="${item%%  *}"; rel="${item#*  }"
    if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]] || [[ ! "$rel" =~ ^[A-Za-z0-9._/-]+$ ]]; then item_fail "the installer's Oracle OPS file manifest is malformed: $item"; return 1; fi
    case "/$rel/" in */../*|*//*|*/./*) item_fail "the installer's Oracle OPS file manifest is malformed: $item"; return 1 ;; esac
    VALIDATE_PATHS+=("$rel")
  done
  return 0
}

# validate_ops_run <script> <arguments...>: ops_run (common.sh) with the working directory RUN_DIR; otherwise identical: umask
# 022, root's HOME, a scrubbed environment, the script of the verified copy.
validate_ops_run() {
  local script="$1"
  shift
  ( cd "$RUN_DIR" || exit 1
    umask 022
    CHILD_HOME="$ROOT_HOME"
    clean_env_exec bash "$OPS_SRC/deploy/scripts/$script" "$@" )
}

# validate_stage: extracts the checked archive. The only tar -x of the read-only checks.
validate_stage() {
  tar -xf "$RUN_DIR/src.tar" -C "$RUN_DIR/src" --no-same-owner --no-same-permissions
}

# 1: the repository
validate_item_repository() {
  local r="$SOURCE_REPO" g
  if ! valid_home "$r"; then item_fail "the repository path '$r' is not usable (an absolute path of plain characters outside system directories)"; item_finish ""; return 0; fi
  if [ -L "$r" ] || [ ! -d "$r" ]; then item_fail "$r is not a real directory"; item_finish ""; return 0; fi
  g="$r/.git"
  if [ -L "$g" ] || [ ! -d "$g" ]; then item_fail "$g is not a real directory (a bare repository, a file or a link is not accepted)"; item_finish ""; return 0; fi
  if [ -L "$g/info/attributes" ] || [ -s "$g/info/attributes" ]; then item_fail "$g/info/attributes is present: repository attributes can change what git archive writes"; fi
  if [ -e "$g/info/grafts" ] || [ -L "$g/info/grafts" ]; then item_fail "$g/info/grafts is present: grafts can change the history git archive reads"; fi
  if [ -L "$g/refs/replace" ]; then
    item_fail "$g/refs/replace is a link"
  elif [ -d "$g/refs/replace" ] && [ -n "$(ls -A "$g/refs/replace" 2>/dev/null)" ]; then
    item_fail "the repository has replace refs ($g/refs/replace): they can substitute objects"
  fi
  if [ -f "$g/packed-refs" ] && grep -q ' refs/replace/' "$g/packed-refs" 2>/dev/null; then item_fail "the repository has packed replace refs"; fi
  item_finish "$r: real directory with a real .git, no attributes, grafts or replace refs"
  return 0
}

# 2: the pinned commit is in the repository
validate_item_commit() {
  local got=""
  item_need git || { item_finish ""; return 0; }
  if got="$(run_as_repo_owner "$SOURCE_REPO" git "--git-dir=$SOURCE_REPO/.git" rev-parse --verify "$OPS_COMMIT^{commit}" 2>/dev/null)"; then :; else got=""; fi
  if [ -z "$got" ]; then
    item_fail "the pinned commit ${OPS_COMMIT:0:12} is not in the repository $SOURCE_REPO"
  elif [ "$got" != "$OPS_COMMIT" ]; then
    item_fail "the repository resolved the pinned commit to ${got:0:12}, expected ${OPS_COMMIT:0:12}"
  fi
  item_finish "the pinned commit ${OPS_COMMIT:0:12} is in $SOURCE_REPO"
  return 0
}

# 3: git archive of exactly the manifest paths from the pinned commit, written by root
validate_item_archive() {
  item_need git || { item_finish ""; return 0; }
  validate_manifest_paths || { item_finish ""; return 0; }
  if ! run_as_repo_owner "$SOURCE_REPO" git "--git-dir=$SOURCE_REPO/.git" archive --format=tar "$OPS_COMMIT" -- "${VALIDATE_PATHS[@]}" > "$RUN_DIR/src.tar" 2> "$RUN_DIR/archive.err"; then
    item_fail "git archive of the pinned commit failed (a manifest file may be missing from it)"
    ITEM_EXTRA="$(head -n 3 "$RUN_DIR/archive.err" 2>/dev/null | cut -c1-200)"
    item_finish ""; return 0
  fi
  item_finish "git archive of ${OPS_COMMIT:0:12} for ${#VALIDATE_PATHS[@]} files written to the run directory"
  return 0
}

# 4: list, extract and verify the archive against the manifest (R1)
validate_item_verify() {
  local listing names l c n item digest rel found expected other got v
  item_need tar sha256sum find sort || { item_finish ""; return 0; }
  validate_manifest_paths || { item_finish ""; return 0; }
  if ! listing="$(tar -tvf "$RUN_DIR/src.tar" 2>/dev/null)"; then item_fail "the archive cannot be listed"; item_finish ""; return 0; fi
  if ! names="$(tar -tf "$RUN_DIR/src.tar" 2>/dev/null)"; then item_fail "the archive cannot be listed"; item_finish ""; return 0; fi
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    c="${l:0:1}"
    case "$c" in -|d) ;; *) item_fail "the archive holds an entry that is neither a regular file nor a directory ('$c'): refused"; item_finish ""; return 0 ;; esac
  done <<< "$listing"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "/$n" in
      //*|*/../*|*/..) item_fail "the archive holds an unsafe name: refused"; item_finish ""; return 0 ;;
    esac
  done <<< "$names"
  if ! validate_stage 2> "$RUN_DIR/extract.err"; then item_fail "the archive could not be extracted"; item_finish ""; return 0; fi
  if ! found="$(find "$RUN_DIR/src" -mindepth 1 -type f -printf '%P\n' | LC_ALL=C sort)"; then item_fail "the extracted files cannot be listed"; item_finish ""; return 0; fi
  if ! other="$(find "$RUN_DIR/src" -mindepth 1 ! -type f ! -type d -printf '%P\n')"; then item_fail "the extracted files cannot be listed"; item_finish ""; return 0; fi
  expected="$(printf '%s\n' "${VALIDATE_PATHS[@]}" | LC_ALL=C sort)"
  [ -z "$other" ] || item_fail "the extraction holds entries that are neither files nor directories"
  [ "$found" = "$expected" ] || item_fail "the extracted files are not exactly the expected set (expected: $(printf '%s' "$expected" | tr '\n' ' '); found: $(printf '%s' "$found" | tr '\n' ' '))"
  if [ -z "$ITEM_FAILS" ]; then
    for item in "${OPS_FILE_MANIFEST[@]}"; do
      digest="${item%%  *}"; rel="${item#*  }"
      if ! got="$(sha256sum -- "$RUN_DIR/src/$rel" 2>/dev/null)"; then item_fail "$rel cannot be hashed"; continue; fi
      got="${got%% *}"
      [ "$got" = "$digest" ] || item_fail "$rel does not match the SHA-256 recorded in this installer for Oracle OPS $OPS_VERSION"
    done
  fi
  if [ -z "$ITEM_FAILS" ]; then
    v="$(head -n 1 "$RUN_DIR/src/service/VERSION" 2>/dev/null)"
    [ "$v" = "$OPS_VERSION" ] || item_fail "service/VERSION is '$v', the installer expects $OPS_VERSION"
  fi
  item_finish "${#VALIDATE_PATHS[@]} files extracted, exactly the expected set, each with its recorded SHA-256; service/VERSION $OPS_VERSION"
  return 0
}

# 5/6: an Oracle OPS check of the verified copy; its output is shown (sanitised) and logged; non-zero is a FAIL
validate_item_ops() {
  local script="$1" rc=0 out="$RUN_DIR/ops-check.out"
  shift
  if [ -z "$STATUS_HOME" ]; then item_fail "no installation directory to check"; item_finish ""; return 0; fi
  validate_ops_run "$script" "$@" --home "$STATUS_HOME" < /dev/null > "$out" 2>&1 || rc=$?
  if [ -s "$out" ]; then ITEM_EXTRA="$(sanitize_stream < "$out")"; fi
  [ "$rc" = 0 ] || item_fail "$script $* --home $STATUS_HOME exited with status $rc"
  item_finish "$script $* --home $STATUS_HOME: exit status 0"
  return 0
}

# the run directory of a command-line validate is removed now, and the removal is reported
validate_item_run_dir() {
  local d="$RUN_DIR"
  if check_finish_run_dir; then item_finish "$d removed"; else item_fail "$d could not be removed; remove it as root after review"; item_finish ""; fi
  return 0
}

# validate_run: status, then the pinned-source checks and the Oracle OPS checks.
validate_run() {
  CHECK_KIND=validate
  OPS_SRC="$RUN_DIR/src"
  VALIDATE_SOURCE_FAILED=0
  check_out "Oracle OPS validation (installer $INSTALLER_VERSION; pinned Oracle OPS $OPS_VERSION, commit ${OPS_COMMIT:0:7}; repository $SOURCE_REPO)"
  status_items
  check_prepare_src
  run_item source-repository validate_item_repository
  [ "$ITEM_STATUS" != FAIL ] || VALIDATE_SOURCE_FAILED=1
  if [ "$VALIDATE_SOURCE_FAILED" = 0 ]; then
    run_item source-commit validate_item_commit
    [ "$ITEM_STATUS" != FAIL ] || VALIDATE_SOURCE_FAILED=1
  fi
  if [ "$VALIDATE_SOURCE_FAILED" = 0 ]; then
    run_item source-archive validate_item_archive
    [ "$ITEM_STATUS" != FAIL ] || VALIDATE_SOURCE_FAILED=1
  fi
  if [ "$VALIDATE_SOURCE_FAILED" = 0 ]; then
    run_item source-verify validate_item_verify
    [ "$ITEM_STATUS" != FAIL ] || VALIDATE_SOURCE_FAILED=1
  fi
  if [ "$VALIDATE_SOURCE_FAILED" = 0 ]; then
    run_item config-validate validate_item_ops config-migrate.sh validate
    run_item service-identity validate_item_ops service-identity.sh check
  else
    check_out "      The pinned Oracle OPS source could not be verified: no Oracle OPS script was run."
  fi
  if [ "$CHECK_OWN_RUN_DIR" = 1 ]; then run_item run-directory validate_item_run_dir; fi
  check_summary "validate"
  if [ "$VALIDATE_SOURCE_FAILED" = 1 ]; then
    CHECK_RC=4
  elif [ "$CHECK_COUNT_FAIL" -gt 0 ]; then
    CHECK_RC=1
  else
    CHECK_RC=0
  fi
  return 0
}

# op_validate: menu choice 6, after the normal start-up; the run directory is the installer's own.
op_validate() {
  local r attempt
  OPERATION="validation"
  status_discover
  [ "$CHECK_NOT_INSTALLED" = 0 ] || finish 6 "Oracle OPS is not installed on this host"
  SOURCE_REPO=""
  for attempt in 1 2 3; do
    printf '      Oracle OPS repository [%s]: ' "$DEFAULT_SOURCE_REPO"
    read_line r || { echo; finish 5 "no repository path was entered"; }
    r="${r:-$DEFAULT_SOURCE_REPO}"
    [ "$r" = "/" ] || r="${r%/}"
    if valid_home "$r"; then SOURCE_REPO="$r"; log "repository: $r"; break; fi
    say "      Not usable: use an absolute path of letters, digits, '.', '_', '-' and '/', outside system directories."
  done
  [ -n "$SOURCE_REPO" ] || finish 2 "no usable repository path after three attempts"
  validate_run
  [ "$CHECK_RC" = 0 ] || finish "$CHECK_RC" "the validation found problems (see the lines above)"
  finish 0
}
