# system-service-common.zsh — manifest parsing shared by the system-service
# workers (launchd on macOS, systemd on Linux). services.toml is the single
# manifest; each worker renders/manages its platform's artifacts from it.
#
# Sourced only, never executed; defines functions and read-only defaults and
# mutates nothing, so it needs no source-guard. REQUIRES
# system-package-common.zsh (die, log_info, PKG_DIR) to be sourced first —
# both workers do so.

# services.toml lives in $PKG_DIR (~/.config/packages by default) so all
# system-package-* state stays in one directory.
SVCFILE="${SVCFILE:-$PKG_DIR/services.toml}"
LABEL_PREFIX="com.system-service"

# svc::toml_json — cached JSON view of services.toml. Empty `{}` if the
# manifest doesn't exist (chezmoi may not have rendered it yet on a
# fresh machine).
svc::toml_json() {
  if [[ -f "$SVCFILE" ]]; then
    yq -p toml -o json '.' "$SVCFILE"
  else
    printf '{}\n'
  fi
}

# svc::names — top-level keys of services.toml, one per line
svc::names() {
  svc::toml_json | jq -r 'keys[]' 2>/dev/null || true
}

# svc::declared <name> → returns 0 iff <name> exists in services.toml
svc::declared() {
  svc::toml_json | jq -e --arg n "$1" 'has($n)' >/dev/null 2>&1
}

# svc::require_declared <name>
# Die unless <name> is a section of services.toml. Every per-name verb guards
# with this so a typo fails with the same message on both platforms.
svc::require_declared() {
  svc::declared "$1" || die "no such service in $SVCFILE: $1"
}

# svc::resolve_cmd0 <cmd0_token>
# Resolve the first cmd token (typically a bare binary name like "omlx") to
# an absolute path. Neither launchd (ProgramArguments[0]) nor a systemd unit
# (ExecStart=, no mise shims on the unit PATH) can search the caller's PATH;
# the rendered artifact must carry an absolute path. Falls back to the
# literal value when `command -v` can't find it — that error surfaces at
# activation time rather than here so the user gets a clean message.
svc::resolve_cmd0() {
  local cmd0="$1"
  if [[ "$cmd0" == /* ]]; then
    printf '%s\n' "$cmd0"
  else
    command -v "$cmd0" 2>/dev/null || printf '%s\n' "$cmd0"
  fi
}

# svc::ensure_dirs <name>
# Make sure WorkingDirectory and the parent dirs of the log paths exist
# before activation — launchd errors out with EX_NOENT (78) and systemd's
# `append:` refuses to create parents; both surface as cryptic spawn
# failures instead of "missing dir".
svc::ensure_dirs() {
  local name="$1"
  svc::toml_json | jq -r --arg n "$name" --arg home "$HOME" '
    .[$n] as $s
    | ($s.working_dir, $s.log_path, $s.error_log_path)
    | select(. != null)
    | sub("^~"; $home)
  ' | while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # log/error paths point at the file itself — strip the basename.
    [[ "$p" == *.log || "$p" == *.out || "$p" == *.err ]] && p="${p:h}"
    mkdir -p "$p"
  done
}

# svc::matching <pkg>
# Print declared service names whose top-level key OR cmd[0] basename
# matches <pkg>. Adopted entries (no cmd) match by key only. Used by
# `system-service restart-for` to map an upgraded package name back to the
# services it owns.
svc::matching() {
  local pkg="$1"
  svc::toml_json | jq -r --arg p "$pkg" '
    to_entries[]
    | select(
        .key == $p
        or ((.value.cmd[0] // "") | split("/") | .[length-1] == $p)
      )
    | .key'
}

# do_matching <pkg>
# The `matching` verb, identical on both platforms. Internal: lets
# `system-service restart-for` query a worker without sourcing it.
do_matching() {
  [[ $# -eq 1 ]] || die "usage: matching <pkg>"
  svc::matching "$1"
}

# svc::print_manifest_entry <name>
# The "manifest entry" block of `info`: the entry's JSON, indented.
svc::print_manifest_entry() {
  printf '  manifest entry:\n'
  svc::toml_json | jq --arg n "$1" '.[$n]' | sed 's/^/    /'
}

# svc::orphans <dir> <suffix> [declared_name...]
# Print, one per line, the service names that have a generated artifact
# <dir>/com.system-service.<name><suffix> but are not among the declared names.
# Scoped to LABEL_PREFIX on purpose: a file the worker did not generate (an
# adopted unit, another tool's plist) can never be reported, so the sweep that
# deletes orphans cannot touch it.
svc::orphans() {
  local dir="$1" suffix="$2"
  shift 2
  local file="" name=""
  for file in "$dir"/${LABEL_PREFIX}.*${suffix}(N); do
    name="${${file:t}#${LABEL_PREFIX}.}"
    name="${name%${suffix}}"
    ((${@[(Ie)$name]})) || print -r -- "$name"
  done
}
