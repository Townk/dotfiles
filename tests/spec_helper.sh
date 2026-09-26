# spec_helper.sh — suite-wide hermetic guard for ShellSpec tests.
#
# Unset ambient Zellij environment variables so specs that do NOT explicitly
# stub/set ZELLIJ always take the non-Zellij (test) path.  Specs that need
# Zellij (workers, action-broker, zellij_spec, assist-agent-common) export
# ZELLIJ=1 themselves in their BeforeEach/setup(), which runs per-example and
# takes precedence over this module-level unset.
unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME
# Same hermetic guard for tmux (the mux.zsh shim dispatches on $TMUX): specs
# that need the tmux backend export TMUX themselves in their setup().
unset TMUX TMUX_PANE

# tm scrub-session debounce: real sessions nap before each synthesis so a
# held key only builds the rung the user settles on — specs step rapidly
# on purpose and would pay the nap dozens of times.
export BKP_TM_SCRUB_DEBOUNCE=0

# Render the single-source palette (.chezmoidata/theme.yaml ->
# custom-builds/theme/templates/palette.zsh.tmpl) to a temp file and point
# common.zsh at it via THEME_PALETTE_FILE, so palette-dependent specs resolve the
# canonical, machine-independent palette rather than any per-machine build
# artifact the ambient shell exported (e.g. ~/.cache/theme/chezmoi-system.zsh,
# which carries this box's background wash). Overriding THEME_PALETTE_FILE here
# keeps the suite hermetic regardless of the invoking shell's environment.
_palette_tpl="custom-builds/theme/templates/palette.zsh.tmpl"
if command -v chezmoi >/dev/null 2>&1 && [ -f "$_palette_tpl" ]; then
  _palette_tmp="$(mktemp 2>/dev/null)"
  if [ -n "${_palette_tmp:-}" ] \
    && chezmoi execute-template <"$_palette_tpl" >"$_palette_tmp" 2>/dev/null \
    && [ -s "$_palette_tmp" ]; then
    export THEME_PALETTE_FILE="$_palette_tmp"
  fi
fi

# A $SHELLSPEC_TMPBASE of each spec file's own. shellspec gives the whole run
# one, and the specs write fixed names under it ($SHELLSPEC_TMPBASE/state,
# /bin, /calls, ...), so under `--jobs` two files using the same name overwrite
# each other's fixtures mid-example. These root hooks run in each file's own
# process, after shellspec has fixed that file's $SHELLSPEC_WORKDIR (which its
# own bookkeeping uses) and around all of its blocks, so the file's top-level
# code, hooks and examples all see the new value. tests/spec_tmpbase_spec.sh
# pins it.
#
# The directory is a sibling of shellspec's, not inside it: recob specs bind
# Unix sockets under it, and macOS caps a socket path at 103 bytes. Under
# shellspec's own base those paths are already 101 bytes long; this one is
# shorter than that base.
spec_helper_configure() {
  before_all spec_helper_own_tmpbase
  after_all spec_helper_drop_tmpbase
}
spec_helper_own_tmpbase() {
  SPEC_HELPER_TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/spec.XXXXXX") || return 1
  SHELLSPEC_TMPBASE=$SPEC_HELPER_TMPBASE
}
spec_helper_drop_tmpbase() {
  [ -n "${SPEC_HELPER_TMPBASE:-}" ] && rm -rf "$SPEC_HELPER_TMPBASE"
  return 0
}

# show_separators CMD [ARGS...] — run CMD and print its stdout with every US
# (\037) as <US> and every RS (\036) as <RS>, returning CMD's own status.
#
# US and RS are the field and record separators of ShellSpec's report stream.
# An expectation or subject that carries them raw splits a report record: the
# reporter evals a garbage field ("command not found: field_..."), the run is
# "Aborted", and ShellSpec 0.28.1 then exits 0 even with failures (see
# tests/run-shellspec.sh). Assert on the visible form instead:
#
#   When call show_separators input::form --spec "$SPEC"
#   The output should equal "name<US>Ada<RS>email<US>yes"
show_separators() {
  _ss_out=$("$@")
  _ss_rc=$?
  # No output stays no output: a lone newline would be unasserted stdout.
  if [ -n "$_ss_out" ]; then
    printf '%s\n' "$_ss_out" | LC_ALL=C sed "s/$(printf '\037')/<US>/g; s/$(printf '\036')/<RS>/g"
  fi
  return "$_ss_rc"
}
