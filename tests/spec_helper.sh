# spec_helper.sh — suite-wide hermetic guard for ShellSpec tests.
#
# Unset ambient Zellij environment variables so specs that do NOT explicitly
# stub/set ZELLIJ always take the non-Zellij (test) path.  Specs that need
# Zellij (workers, action-broker, zellij_spec, assist-agent-common) export
# ZELLIJ=1 themselves in their BeforeEach/setup(), which runs per-example and
# takes precedence over this module-level unset.
unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME
