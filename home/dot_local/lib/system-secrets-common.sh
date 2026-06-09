# system-secrets-common.sh — shared helpers for `system-onboard` and
# `system-secrets`. Intended to be sourced; does not run on its own.
#
# Both commands share this library so the onboarding path and the later
# add/rotate path cannot drift in how they name slots, render fragments,
# encrypt blobs, or audit for leaks. Mirrors the system-package-common.sh
# pattern.
#
# HARD CONSTRAINT (this repo is PUBLIC): committed artifacts use OPAQUE SLOT
# IDS only — never a machine alias, hostname, username, or work tool name.
# Real endpoints and the alias<->slot map live in the loose, unmanaged layer
# (~/.ssh/config.d/*, the operator map). Every commit path runs sec_leak_audit.

# ---------------------------------------------------------------------------
# Output helpers (respect non-tty stdout), matching system-package-common.sh.
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  SEC_C_BLU=$'\e[34m'
  SEC_C_GRN=$'\e[32m'
  SEC_C_RED=$'\e[31m'
  SEC_C_YEL=$'\e[33m'
  SEC_C_BWH=$'\e[1;37m'
  SEC_C_RES=$'\e[0m'
else
  SEC_C_BLU=""; SEC_C_GRN=""; SEC_C_RED=""; SEC_C_YEL=""; SEC_C_BWH=""; SEC_C_RES=""
fi

sec_info()  { printf '%s=>%s %s\n' "$SEC_C_BLU" "$SEC_C_RES" "$*"; }
sec_ok()    { printf '%s✓%s %s\n'  "$SEC_C_GRN" "$SEC_C_RES" "$*"; }
sec_warn()  { printf '%swarn:%s %s\n' "$SEC_C_YEL" "$SEC_C_RES" "$*" >&2; }
sec_error() { printf '%serror:%s %s\n' "$SEC_C_RED" "$SEC_C_RES" "$*" >&2; }
sec_die()   { sec_error "$*"; exit 1; }

sec_is_help() {
  case "${1:-}" in
    -h|--help|help) return 0 ;;
    *)              return 1 ;;
  esac
}

sec_args_contain_help() {
  local a=""
  for a in "$@"; do
    case "$a" in -h|--help) return 0 ;; esac
  done
  return 1
}

# sec_require_cmd <cmd>... — die unless every command is on PATH.
sec_require_cmd() {
  local c="" missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) || sec_die "missing required tool(s): ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Repository paths. Resolves the chezmoi source dir, the git work tree (repo
# root), and every secret-related path relative to them. The repo root is the
# parent of the chezmoi source dir (.chezmoiroot = home).
# ---------------------------------------------------------------------------
sec_repo_paths() {
  SECRETS_SRC_DIR="$(chezmoi source-path)" \
    || sec_die "cannot resolve chezmoi source path (is chezmoi installed?)"
  REPO_ROOT="$(git -C "$SECRETS_SRC_DIR" rev-parse --show-toplevel)" \
    || sec_die "chezmoi source dir is not a git work tree: $SECRETS_SRC_DIR"
  MANIFEST="$SECRETS_SRC_DIR/.chezmoidata/secrets.yaml"
  FRAGMENT_DIR="$SECRETS_SRC_DIR/dot_config/zsh/private_secrets.d"
  SECRETS_BLOB_DIR="$REPO_ROOT/secrets"
  SOPS_YAML="$REPO_ROOT/.sops.yaml"
  OPERATOR_MAP="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/onboard-map.yaml"
  LEAK_PATTERNS="$REPO_ROOT/.leak-patterns"
  # Path of the age identity on a (headless) target, relative to its $HOME.
  AGE_KEY_REL=".local/state/chezmoi/secrets/key.txt"
}

# ---------------------------------------------------------------------------
# Manifest queries (env var names + prompts + requiredFor profiles).
# ---------------------------------------------------------------------------
sec_manifest_check() {
  [[ -r "$MANIFEST" ]] || sec_die "secrets manifest not found: $MANIFEST"
}

# sec_manifest_names — every declared secret name, one per line.
sec_manifest_names() {
  sec_manifest_check
  yq -r '.secrets[].name' "$MANIFEST"
}

# sec_manifest_names_for_profile <profile> — names whose requiredFor includes
# <profile>, one per line.
sec_manifest_names_for_profile() {
  sec_manifest_check
  profile="$1" yq -r \
    '.secrets[] | select(.requiredFor[] == strenv(profile)) | .name' \
    "$MANIFEST"
}

# sec_manifest_prompt <name> — the human prompt for a secret.
sec_manifest_prompt() {
  sec_manifest_check
  name="$1" yq -r \
    '.secrets[] | select(.name == strenv(name)) | .prompt' \
    "$MANIFEST"
}

# sec_manifest_has <name> — return 0 iff the secret is declared.
sec_manifest_has() {
  sec_manifest_check
  local hit
  hit="$(name="$1" yq -r \
    '[.secrets[] | select(.name == strenv(name))] | length' "$MANIFEST")"
  [[ "$hit" != "0" ]]
}

# ---------------------------------------------------------------------------
# Interactive prompt helpers. Raw read/read -s for v1 (no gum dependency in a
# bootstrap-adjacent tool; predictable over SSH for secret entry). Isolated
# here so a future gum backend can drop in. All read from /dev/tty so prompts
# work even when stdin is a pipe.
# ---------------------------------------------------------------------------
sec_have_tty() { [[ -t 0 || -e /dev/tty ]]; }

# prompt_required <varname> <prompt> — loop until non-empty; sets the named var.
prompt_required() {
  local __var="$1" __prompt="$2" __val=""
  while :; do
    printf '%s%s%s ' "$SEC_C_BWH" "$__prompt" "$SEC_C_RES" >/dev/tty
    IFS= read -r __val </dev/tty || sec_die "input aborted"
    [[ -n "$__val" ]] && break
    sec_warn "a value is required"
  done
  printf -v "$__var" '%s' "$__val"
}

# prompt_default <varname> <prompt> <default> — empty input keeps the default.
prompt_default() {
  local __var="$1" __prompt="$2" __default="$3" __val=""
  printf '%s%s%s [%s] ' "$SEC_C_BWH" "$__prompt" "$SEC_C_RES" "$__default" >/dev/tty
  IFS= read -r __val </dev/tty || sec_die "input aborted"
  [[ -n "$__val" ]] || __val="$__default"
  printf -v "$__var" '%s' "$__val"
}

# prompt_secret <varname> <prompt> — no echo; loops until non-empty.
prompt_secret() {
  local __var="$1" __prompt="$2" __val=""
  while :; do
    printf '%s%s%s ' "$SEC_C_BWH" "$__prompt" "$SEC_C_RES" >/dev/tty
    IFS= read -rs __val </dev/tty || sec_die "input aborted"
    printf '\n' >/dev/tty
    [[ -n "$__val" ]] && break
    sec_warn "a value is required"
  done
  printf -v "$__var" '%s' "$__val"
}

# prompt_choice <varname> <prompt> <opt>... — accept only a listed option.
prompt_choice() {
  local __var="$1" __prompt="$2"; shift 2
  local __opts=("$@") __val="" __o=""
  while :; do
    printf '%s%s%s (%s) ' "$SEC_C_BWH" "$__prompt" "$SEC_C_RES" "${(j:/:)__opts}" >/dev/tty
    IFS= read -r __val </dev/tty || sec_die "input aborted"
    for __o in "${__opts[@]}"; do
      [[ "$__val" == "$__o" ]] && { printf -v "$__var" '%s' "$__val"; return 0; }
    done
    sec_warn "choose one of: ${(j:, :)__opts}"
  done
}

# confirm <prompt> — return 0 on yes, 1 on no (default no).
confirm() {
  local __ans=""
  printf '%s%s%s [y/N] ' "$SEC_C_BWH" "$1" "$SEC_C_RES" >/dev/tty
  IFS= read -r __ans </dev/tty || return 1
  [[ "$__ans" == [yY] || "$__ans" == [yY][eE][sS] ]]
}

# ---------------------------------------------------------------------------
# Slot ids and slot-derived paths.
# ---------------------------------------------------------------------------
# sec_gen_slot — emit a fresh opaque slot id: slot-<6 hex>. Non-identifying.
# Reads a fixed 4 bytes (no producer-side SIGPIPE under pipefail) and keeps 6
# hex chars. Not crypto-grade; collisions are caught against the operator map.
sec_gen_slot() {
  local hex
  hex="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-6)"
  [[ ${#hex} -eq 6 ]] || hex="$(printf '%06x' $(( (RANDOM * 65536 + RANDOM) % 16777216 )))"
  printf 'slot-%s' "$hex"
}

# sec_valid_slot <slot> — return 0 iff slot matches the opaque-id shape.
sec_valid_slot() {
  [[ "$1" == slot-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9] ]]
}

# sec_valid_name <name> — return 0 iff <name> is a valid env var name.
sec_valid_name() { [[ "$1" =~ '^[A-Z][A-Z0-9_]*$' ]]; }

sec_fragment_path() { printf '%s/private_%s.sh.tmpl' "$FRAGMENT_DIR" "$1"; }
sec_blob_path()     { printf '%s/%s.sops.sh' "$SECRETS_BLOB_DIR" "$1"; }

# ---------------------------------------------------------------------------
# Operator map — LOOSE, NEVER COMMITTED. Lives under ~/.config/chezmoi/.
# Maps each opaque slot to the operator-only facts needed to manage it:
#   <slot>: { alias, profile, kind, recipient }
# alias/host are the leak-sensitive bits and stay here, off git.
# ---------------------------------------------------------------------------
sec_map_init() {
  if [[ ! -f "$OPERATOR_MAP" ]]; then
    mkdir -p "${OPERATOR_MAP:h}"
    printf '{}\n' >"$OPERATOR_MAP"
    chmod 0600 "$OPERATOR_MAP"
  fi
}

# sec_map_get <slot> <field> — print a field value (empty if unset). Read-only:
# never creates the map (so --dry-run has no side effects).
sec_map_get() {
  [[ -f "$OPERATOR_MAP" ]] || { printf ''; return 0; }
  slot="$1" field="$2" yq -r \
    '.[strenv(slot)][strenv(field)] // ""' "$OPERATOR_MAP"
}

# sec_map_set <slot> <alias> <profile> <kind> <recipient>
sec_map_set() {
  sec_map_init
  slot="$1" alias="$2" profile="$3" kind="$4" recipient="$5" yq -i '
    .[strenv(slot)] = {
      "alias": strenv(alias),
      "profile": strenv(profile),
      "kind": strenv(kind),
      "recipient": strenv(recipient)
    }' "$OPERATOR_MAP"
}

# sec_map_slot_for_alias <alias> — print the slot mapped to <alias> (or empty).
# Read-only: never creates the map.
sec_map_slot_for_alias() {
  [[ -f "$OPERATOR_MAP" ]] || { printf ''; return 0; }
  alias="$1" yq -r \
    'to_entries | map(select(.value.alias == strenv(alias))) | .[0].key // ""' \
    "$OPERATOR_MAP"
}

# ---------------------------------------------------------------------------
# SOPS + age. Blobs are BINARY-store sops files at secrets/<slot>.sops.sh whose
# decrypted bytes are a ready-to-source `export NAME=value` snippet — shell
# quoting is done here (in shell), so the decrypt template is a verbatim
# passthrough. The .sops.yaml creation rule mirrors each slot's recipient so
# `sops updatekeys` and review work; the recipient is passed explicitly to
# encrypt so it never depends on cwd.
# ---------------------------------------------------------------------------

# sec_sops_rule_set <slot> <recipient> — upsert the slot's creation rule.
sec_sops_rule_set() {
  local slot="$1" recipient="$2"
  [[ -f "$SOPS_YAML" ]] || printf 'creation_rules: []\n' >"$SOPS_YAML"
  re="secrets/${slot}\\.sops\\.sh\$" age="$recipient" yq -i '
    .creation_rules = ((.creation_rules // [])
      | map(select(.path_regex != strenv(re)))
      + [{"path_regex": strenv(re), "age": strenv(age)}])
  ' "$SOPS_YAML"
}

# sec_sops_recipient_for_slot <slot> — recipient from .sops.yaml (or empty).
sec_sops_recipient_for_slot() {
  [[ -f "$SOPS_YAML" ]] || { printf ''; return 0; }
  re="secrets/${1}\\.sops\\.sh\$" yq -r \
    '(.creation_rules // [])[] | select(.path_regex == strenv(re)) | .age' \
    "$SOPS_YAML" 2>/dev/null | head -n1
}

# sec_sops_encrypt <recipient> <plaintext_file> <blob_path>
# Encrypt to a temp file first, then move into place, so a failure never leaves
# a partial or plaintext blob at the destination.
sec_sops_encrypt() {
  local recipient="$1" plain="$2" blob="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/sec-blob.XXXXXX")"
  # --config /dev/null: encrypt to the explicit recipient and ignore the repo
  # .sops.yaml (whose creation rules match the blob path, not this temp input).
  # .sops.yaml stays the committed mirror used by `sops updatekeys`/review.
  if ! sops --config /dev/null --encrypt --age "$recipient" \
        --input-type binary --output-type binary "$plain" >"$tmp"; then
    rm -f "$tmp"
    sec_die "sops encryption failed for recipient $recipient"
  fi
  mv "$tmp" "$blob"
}

# sec_sops_updatekeys <blob_path> — re-encrypt the data key to whatever
# recipients .sops.yaml now lists (used after a recipient rotation).
sec_sops_updatekeys() {
  ( cd "$REPO_ROOT" && sops updatekeys --yes "$1" ) \
    || sec_die "sops updatekeys failed for $1"
}

# ---------------------------------------------------------------------------
# Fragment template writers. Each writes home/.../private_secrets.d/
# private_<slot>.sh.tmpl, which chezmoi renders to ~/.config/zsh/secrets.d/
# <slot>.sh (0600) only on the host whose secretsSlot matches (.chezmoiignore).
# ---------------------------------------------------------------------------

# sec_write_headless_fragment <slot> — body is a single SOPS decrypt call.
sec_write_headless_fragment() {
  local slot="$1" frag
  frag="$(sec_fragment_path "$slot")"
  mkdir -p "${frag:h}"
  cat >"$frag" <<EOF
{{- /* headless slot ${slot}: SOPS+age secrets, decrypted ONCE per apply into
       a 0600 file (the private_ source prefix). The ciphertext blob lives at
       repo-root secrets/${slot}.sops.sh, outside the chezmoi source root, so
       it is read by path and never rendered into \$HOME. sops finds the age
       identity through SOPS_AGE_KEY_FILE, set in chezmoi's [env] on headless
       hosts. The decrypted bytes are already \`export NAME=value\` lines. */ -}}
{{ output "sops" "--decrypt" (joinPath .chezmoi.sourceDir ".." "secrets" "${slot}.sops.sh") }}
EOF
}

# sec_write_human_fragment <slot> <NAME=op://ref>... — onepasswordRead lines.
# References are op:// only (no SOPS, no ciphertext). Each value is rendered
# inside double quotes; op field contents may contain spaces/metacharacters.
sec_write_human_fragment() {
  local slot="$1"; shift
  local frag pair name ref
  frag="$(sec_fragment_path "$slot")"
  mkdir -p "${frag:h}"
  {
    printf '%s\n' "{{- /* human slot ${slot}: 1Password references resolved at apply (no SOPS). */ -}}"
    for pair in "$@"; do
      name="${pair%%=*}"
      ref="${pair#*=}"
      printf 'export %s="{{ onepasswordRead "%s" }}"\n' "$name" "$ref"
    done
  } >"$frag"
}

# ---------------------------------------------------------------------------
# Leak audit. Mirrors the local pre-commit hook: scan STAGED added lines and
# staged file names against the gitignored .leak-patterns. Run this in-tool
# right before committing so a leak fails early with a clear message instead of
# being caught (more opaquely) by the hook. No patterns file -> allow.
# ---------------------------------------------------------------------------
sec_leak_audit() {
  [[ -r "$LEAK_PATTERNS" ]] || return 0
  local added names haystack pat hits=""
  added="$(git -C "$REPO_ROOT" diff --cached -U0 --no-color --diff-filter=AM \
    | grep '^+' | grep -v '^+++' || true)"
  names="$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR || true)"
  haystack="$added
$names"
  [[ -n "${haystack//[[:space:]]/}" ]] || return 0
  while IFS= read -r pat; do
    case "$pat" in ''|\#*) continue ;; esac
    if printf '%s\n' "$haystack" | grep -iEq -- "$pat"; then
      hits="$hits  - $pat"$'\n'
    fi
  done <"$LEAK_PATTERNS"
  if [[ -n "$hits" ]]; then
    sec_error "staged changes match work/company leak patterns:"
    printf '%s' "$hits" >&2
    sec_die "move work-specific data to the loose/unmanaged layer; this repo is public."
  fi
}

# ---------------------------------------------------------------------------
# Slot (re)build — the shared core used by BOTH onboarding (new slot) and
# `system-secrets` rotate/reconcile (existing slot), so the two paths cannot
# drift. (Re)collects every secret the slot's profile requires and regenerates
# its fragment (+ encrypted blob for headless). The caller commits.
#
# Headless note: the operator holds only the box's age PUBLIC key (recipient),
# never its private key, so a blob cannot be partially decrypted/patched — a
# rebuild always re-collects the full required set and re-encrypts. This is the
# per-machine-isolation tradeoff (a compromised box can't read peers' secrets).
# ---------------------------------------------------------------------------

# sec_rebuild_slot <slot> — regenerate fragment/blob from freshly prompted
# values. Reads kind/profile/recipient from the operator map.
sec_rebuild_slot() {
  local slot="$1" kind profile recipient
  kind="$(sec_map_get "$slot" kind)"
  profile="$(sec_map_get "$slot" profile)"
  [[ -n "$kind" && -n "$profile" ]] \
    || sec_die "slot $slot is not in the operator map (run system-onboard first)"

  local names
  names=("${(@f)$(sec_manifest_names_for_profile "$profile")}")
  names=(${names:#})
  (( ${#names[@]} )) || { sec_warn "manifest lists no secrets for profile '$profile'"; return 0; }

  local n val ref
  if [[ "$kind" == headless ]]; then
    recipient="$(sec_map_get "$slot" recipient)"
    [[ -n "$recipient" ]] || recipient="$(sec_sops_recipient_for_slot "$slot")"
    [[ -n "$recipient" ]] || sec_die "no age recipient known for headless slot $slot"
    local plain
    plain="$(mktemp "${TMPDIR:-/tmp}/sec-plain.XXXXXX")"
    chmod 0600 "$plain"
    trap 'rm -f "$plain"' EXIT
    sec_info "Enter values for the '$profile' secrets (hidden). Headless slot $slot:"
    for n in "${names[@]}"; do
      prompt_secret val "  $n — $(sec_manifest_prompt "$n"):"
      printf 'export %s=%s\n' "$n" "${(qq)val}" >>"$plain"
    done
    mkdir -p "$SECRETS_BLOB_DIR"
    sec_sops_rule_set "$slot" "$recipient"
    sec_sops_encrypt "$recipient" "$plain" "$(sec_blob_path "$slot")"
    rm -f "$plain"; trap - EXIT
    sec_write_headless_fragment "$slot"
    sec_ok "encrypted ${#names[@]} secret(s) for slot $slot"
  else
    local pairs=()
    sec_info "Enter 1Password references for the '$profile' secrets. Human slot $slot:"
    for n in "${names[@]}"; do
      prompt_required ref "  $n — op:// reference ($(sec_manifest_prompt "$n")):"
      pairs+=("$n=$ref")
    done
    sec_write_human_fragment "$slot" "${pairs[@]}"
    sec_ok "wrote ${#names[@]} 1Password reference(s) for slot $slot"
  fi
}

# sec_commit_paths_for_slot <slot> — the committed paths a slot touches.
sec_commit_paths_for_slot() {
  local slot="$1"
  printf '%s\n' \
    "$(sec_fragment_path "$slot")" \
    "$SOPS_YAML" \
    "$MANIFEST"
  [[ -f "$(sec_blob_path "$slot")" ]] && printf '%s\n' "$(sec_blob_path "$slot")"
}

# sec_git_commit <message> <path>... — stage paths (relative to repo root),
# run the leak audit, then commit. Refuses if nothing staged.
sec_git_commit() {
  local msg="$1"; shift
  local p
  for p in "$@"; do
    git -C "$REPO_ROOT" add -- "$p" 2>/dev/null || true
  done
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    sec_info "nothing to commit"
    return 0
  fi
  sec_leak_audit
  git -C "$REPO_ROOT" commit -m "$msg" >/dev/null \
    || sec_die "git commit failed"
  sec_ok "committed: $msg"
}
