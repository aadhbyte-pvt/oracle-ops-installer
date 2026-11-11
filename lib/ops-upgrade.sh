#!/bin/bash
# Oracle OPS Installer library: action: upgrade
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

op_upgrade() {
  local rc=0 mode="install" c offset from
  OPERATION="upgrade"; STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  require_installation
  from="${INST_RELEASE:-none}"
  say "      Found Oracle OPS $from at $INST_HOME (service account $INST_USER:$INST_GROUP)."
  if [ "$INST_RELEASE" = "$OPS_VERSION" ] && commit_matches_pin "$INST_COMMIT"; then
    if [ "$INST_ACTIVE" = yes ]; then
      SUCCESS_TEXT="Oracle OPS $OPS_VERSION is already installed and running. Nothing was changed."
      finish 0
    fi
    finish 6 "release $OPS_VERSION is already the active release but $UNIT_NAME is not running; check it with 'systemctl status $UNIT_NAME'"
  fi
  if [ -e "$INST_HOME/releases/$OPS_VERSION" ] || [ -L "$INST_HOME/releases/$OPS_VERSION" ]; then
    c="$(jar_commit "$INST_HOME" "$OPS_VERSION")"
    if commit_matches_pin "$c" && [ "$INST_RELEASE" != "$OPS_VERSION" ]; then
      mode="activate"
      say "      Release $OPS_VERSION is already deployed but not active (an earlier upgrade did not finish)."
    else
      finish 6 "release $OPS_VERSION is already installed at $INST_HOME but was built from different source (commit ${c:-unknown}); the pinned release cannot replace it under the same version number, a new Oracle OPS version is required"
    fi
  fi
  if [ ! -f "$INST_HOME/config/application.yaml" ] || [ ! -f "$CRED_DIR/database.credentials" ]; then
    finish 6 "the existing installation has no $INST_HOME/config/application.yaml or $CRED_DIR/database.credentials; an upgrade needs both in place"
  fi
  stage 3 "Configuring source..."
  get_source
  if [ "$mode" = install ]; then
    say "      Checking the upgrade (no changes yet)..."
    run_quiet "install-release.sh --preflight" ops_run install-release.sh --preflight --home "$INST_HOME" \
      --user "$INST_USER" --group "$INST_GROUP" ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} "$OPS_SRC/service" \
      || finish 1 "the upgrade pre-check failed; nothing was changed"
  fi
  say "      Oracle OPS at $INST_HOME will be upgraded from $from to $OPS_VERSION."
  say "      Oracle OPS is stopped and restarted (EBS is not affected); release $from stays installed."
  confirm_yes "Upgrade now?" || finish 5 "the upgrade was not confirmed; nothing was changed"
  stage 4 "Upgrading Oracle OPS..."
  offset="$(log_size "$INST_HOME")"
  if [ "$mode" = install ]; then
    run_quiet "install-release.sh" ops_run install-release.sh --home "$INST_HOME" --user "$INST_USER" --group "$INST_GROUP" \
      ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} "$OPS_SRC/service" || rc=$?
  else
    run_quiet "activate-release.sh" ops_run activate-release.sh --home "$INST_HOME" --release "$OPS_VERSION" || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    log "rollback, if needed: activate-release.sh --home $INST_HOME --release $from (Oracle OPS deploy/scripts)"
    finish 1 "the Oracle OPS upgrade script failed (exit $rc); release $from is still installed"
  fi
  stage 5 "Finalizing upgrade..."
  verify_installed "$INST_HOME" || finish 1 "the upgrade could not be verified: $VERIFY_PROBLEMS"
  db_healthy_since "$INST_HOME" "$offset" || finish 1 "Oracle OPS $OPS_VERSION started but did not report a healthy database connection"
  run_quiet "service-identity.sh check" ops_run service-identity.sh check --home "$INST_HOME" \
    || finish 1 "the service account check after the upgrade reported deviations"
  SUCCESS_TEXT="Oracle OPS upgrade completed successfully.
Release $OPS_VERSION (commit ${OPS_COMMIT:0:7}) is running from $INST_HOME; release $from is kept for rollback."
  finish 0
}
