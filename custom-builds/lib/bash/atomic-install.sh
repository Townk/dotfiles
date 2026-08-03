#!/usr/bin/env bash
# atomic-install.sh — shared stage → validate → atomic-swap → rollback for the
# custom-build installers (build-zsh.sh, build-colorscripts.sh). SOURCED,
# never executed; defines functions only, no side effects, so no source-guard
# is needed.
#
# The two builders carried byte-identical copies of this function (born
# together, edited in lockstep — the c741998 rollback fix had to be applied
# twice and its test coverage had already drifted). The swap policy is
# safety-critical for build-zsh: $PREFIX is the registered login shell.
#
# Caller contract — everything resolves at CALL time, which is what lets
# tests/atomic_publish_spec.sh source a builder and stub the seams afterwards:
#   install_stage <dir>   build/copy the tree into <dir>; non-zero on failure
#   validate_stage <dir>  self-test the tree at <dir>;   non-zero on failure
#   die <msg>             report and abort (each builder has its own)
#   PREFIX / STAGE / BACKUP  same-parent sibling paths (mv == rename(2))
#   SWAP_LABEL            human name of the validate step for messages, e.g.
#                         "validation" or "self-test ('colorscript -e square')"
#
# IMPORTANT: both run_onchange build hooks bake this file's SHA-256 next to
# their builder's, so editing this file re-fires the builds. If you add a
# third consumer, extend its hook's signature the same way.

# stage_and_swap — install into $STAGE, validate there, atomically replace
# $PREFIX keeping $BACKUP for rollback. The live $PREFIX is only moved aside
# (never removed) and is restored on any failure, so a failed
# install/validate/swap can never leave the machine without a working install.
stage_and_swap() {
  rm -rf -- "$STAGE" "$BACKUP"

  if ! install_stage "$STAGE"; then
    rm -rf -- "$STAGE"
    die "install into staging prefix failed; live install left intact"
  fi
  if ! validate_stage "$STAGE"; then
    rm -rf -- "$STAGE"
    die "staged tree failed ${SWAP_LABEL:-validation}; live install left intact"
  fi

  # Atomic swap: park the live tree, move staging into place, and only then, on
  # confirmed success, drop the backup. A failed final move rolls back.
  if [[ -e "$PREFIX" ]]; then
    mv -- "$PREFIX" "$BACKUP" || die "could not park live prefix; live install left intact"
  fi
  if ! mv -- "$STAGE" "$PREFIX"; then
    [[ -e "$BACKUP" ]] && mv -- "$BACKUP" "$PREFIX"
    die "could not move staged tree into place; rolled back to previous install"
  fi

  # Authoritative post-swap re-validation with natural, baked-in paths. If it
  # fails, secure the rollback BEFORE discarding anything: park the failed tree
  # back in $STAGE (vacated by the swap above), restore the backup, and only
  # then drop the parked tree. Deleting first would leave the machine with no
  # working install if the restore then failed or was interrupted.
  if ! validate_stage "$PREFIX"; then
    mv -- "$PREFIX" "$STAGE" || die "post-swap ${SWAP_LABEL:-validation} failed; could not park the failed tree, leaving it at $PREFIX"
    if [[ -e "$BACKUP" ]] && mv -- "$BACKUP" "$PREFIX"; then
      rm -rf -- "$STAGE"
      die "post-swap ${SWAP_LABEL:-validation} failed; rolled back to previous install"
    fi
    mv -- "$STAGE" "$PREFIX" || true
    die "post-swap ${SWAP_LABEL:-validation} failed; no previous install to roll back to (failed tree left at $PREFIX)"
  fi
  rm -rf -- "$BACKUP"
}
