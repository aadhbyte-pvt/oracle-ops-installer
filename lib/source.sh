#!/bin/bash
# Oracle OPS Installer library: source: token, access check, download, verification
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---------------------------------------------------------------------------------------------------------------------------
# Source: token, access check, download, verification, token destruction
# ---------------------------------------------------------------------------------------------------------------------------

read_token() {
  local t attempt
  say "      Oracle OPS is downloaded from its private GitHub repository. Enter a GitHub access token"
  say "      with read-only access to that repository. The token is not shown, stored or logged."
  for attempt in 1 2 3; do
    printf '      Access token: '
    IFS= read -r -s t || { echo; t=""; finish 5 "no access token was entered"; }
    echo
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"   # a pasted token may carry a newline or spaces
    if [[ "$t" =~ ^[A-Za-z0-9_]{20,255}$ ]]; then TOKEN="$t"; t=""; return 0; fi
    t=""
    say "      That is not a GitHub access token. Try again."
  done
  finish 4 "no valid access token was entered"
}

# The token file lives in a root-only directory on RAM-backed /run when that is safe, else in the run directory. The askpass
# helper holds no secret: it answers git's two prompts for the expected host only and refuses every other prompt.
make_auth() {
  if is_tmpfs "$AUTH_BASE" && ensure_private_dir_parent_ok "$AUTH_BASE"; then
    AUTH_DIR="$(mktemp -d "$AUTH_BASE/oracle-ops-installer.XXXXXXXX")" || finish 1 "cannot create a temporary directory in $AUTH_BASE"
  else
    AUTH_DIR="$RUN_DIR/auth"
    mkdir -m 0700 "$AUTH_DIR" || finish 1 "cannot create a temporary directory in $RUN_DIR"
  fi
  [[ "$AUTH_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || finish 1 "internal error: unexpected temporary directory name"
  printf '%s %s\n' "$MARKER_TEXT" "$BASHPID" > "$AUTH_DIR/$MARKER_NAME"
  ( umask 077; printf '%s\n' "$TOKEN" > "$AUTH_DIR/token" ) || finish 1 "cannot write the temporary token file"
  cat > "$AUTH_DIR/askpass" <<EOF
#!/bin/sh
# Oracle OPS Installer: answers git's credential prompts for ${GIT_HOST_URL} only. It holds no secret.
case "\$1" in
  "Username for '${GIT_HOST_URL}'"*) printf '%s\n' '${GIT_USERNAME}' ;;
  "Password for '${GIT_PASSWORD_URL}'"*) exec cat -- '${AUTH_DIR}/token' ;;
  *) exit 1 ;;
esac
EOF
  chmod 0700 "$AUTH_DIR/askpass"
  log "temporary credential helper created in $AUTH_DIR (token file mode 0600)"
}

classify_git_failure() {  # classify_git_failure <exit status>: a short, secret-free reason from the captured output
  local rc="$1"
  if [ "$rc" = 124 ]; then echo "the connection to GitHub timed out"; return 0; fi
  if grep -qiE 'Authentication failed|Invalid username or password|HTTP Basic: Access denied|returned error: 40[13]' "$CAPTURE" 2>/dev/null; then
    echo "GitHub rejected the access token"; return 0
  fi
  if grep -qiE 'Repository not found|repository .* not found|returned error: 404' "$CAPTURE" 2>/dev/null; then
    echo "the access token has no access to the Oracle OPS repository"; return 0
  fi
  if grep -qiE 'Could not resolve|Couldn.t resolve|Failed to connect|Connection (timed out|refused|reset)|Network is unreachable|SSL|TLS|early EOF|RPC failed|unable to access' "$CAPTURE" 2>/dev/null; then
    echo "GitHub could not be reached over HTTPS, or the download was interrupted"; return 0
  fi
  echo "the Oracle OPS source could not be downloaded"
}

verify_source() {
  local head dirty v f platforms
  run_quiet "check that the pinned commit is present" git_local cat-file -e "$OPS_COMMIT^{commit}" \
    || finish 4 "the pinned Oracle OPS release ${OPS_COMMIT:0:12} is not available in the repository"
  run_quiet "check out the pinned commit" git_local -c advice.detachedHead=false checkout --quiet --detach "$OPS_COMMIT" \
    || finish 4 "the pinned Oracle OPS release could not be checked out"
  head="$(git_local rev-parse HEAD 2>/dev/null)" || head=""
  [ "$head" = "$OPS_COMMIT" ] || finish 4 "the downloaded source is not the pinned commit"
  dirty="$(git_local status --porcelain 2>/dev/null | head -n 1)" || dirty="unknown"
  [ -z "$dirty" ] || finish 4 "the downloaded source does not match the pinned commit exactly"
  for f in service/VERSION service/build.sh deploy/java-runtime.properties deploy/scripts/deploy-oracle-ops.sh \
           deploy/scripts/install-release.sh deploy/scripts/activate-release.sh deploy/scripts/service-identity.sh \
           deploy/scripts/manage-app-credentials.sh deploy/scripts/ownership-lib.sh deploy/scripts/provision-java.sh; do
    if [ ! -f "$OPS_SRC/$f" ] || [ -L "$OPS_SRC/$f" ]; then finish 4 "the downloaded release lacks $f (installer and release do not match)"; fi
  done
  v="$(head -n 1 "$OPS_SRC/service/VERSION")"
  [ "$v" = "$OPS_VERSION" ] || finish 4 "the downloaded release is version '$v', the installer expects $OPS_VERSION"
  platforms="$(sed -n 's/^jdk\.platforms=//p' "$OPS_SRC/deploy/java-runtime.properties" | head -n 1)"
  in_list "$(host_platform)" "$platforms" || finish 4 "this Oracle OPS release does not support $(host_platform) (it supports: ${platforms:-none})"
  log "source verified: HEAD=$head VERSION=$v jdk.platforms=$platforms"
}

# Stage "Configuring source": ask for the token, prove access, download, destroy the token, verify. The token and the helper
# are removed BEFORE any downloaded code runs, so nothing from the repository can read them.
get_source() {
  local rc=0 reason
  read_token
  make_auth
  say "      Checking repository access..."
  run_quiet "check repository access" git_net "$GIT_LS_REMOTE_TIMEOUT" ls-remote --heads "$OPS_REPO_URL" || rc=$?
  if [ "$rc" != 0 ]; then reason="$(classify_git_failure "$rc")"; destroy_auth; finish 4 "$reason"; fi
  say "      Downloading Oracle OPS $OPS_VERSION..."
  OPS_SRC="$RUN_DIR/src"
  run_quiet "download the Oracle OPS source" git_net "$GIT_CLONE_TIMEOUT" clone --quiet --no-checkout "$OPS_REPO_URL" "$OPS_SRC" || rc=$?
  if [ "$rc" != 0 ]; then
    reason="$(classify_git_failure "$rc")"
    destroy_auth
    if [ -e "$OPS_SRC" ]; then rm -rf --one-file-system -- "$OPS_SRC" && log "removed the incomplete download"; fi
    finish 4 "$reason"
  fi
  destroy_auth
  log "access token and credential helper removed"
  say "      Verifying the downloaded release..."
  verify_source
}
