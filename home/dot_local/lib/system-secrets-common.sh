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

# prompt_secret <varname> <prompt> — masked entry: echoes a '*' per keystroke
# instead of the usual blind no-echo read, so there's visual feedback while
# typing/pasting a secret. Supports Backspace and ^U (clear). Reads raw, one
# char at a time, with the tty put in -echo -icanon; the terminal is always
# restored, including on ^C. Falls back to a plain no-echo read when there is
# no controlling terminal (pipelines/tests). Loops until non-empty.
prompt_secret() {
  local __var="$1" __prompt="$2" __val=""

  if ! sec_have_tty; then
    IFS= read -rs __val </dev/tty 2>/dev/null || IFS= read -rs __val \
      || sec_die "input aborted"
    printf -v "$__var" '%s' "$__val"
    return 0
  fi

  local __saved __ch
  # If we can't capture/drive the tty (no controlling terminal, restricted
  # environment), fall back to a blind no-echo read rather than spin.
  if ! __saved="$(stty -g </dev/tty 2>/dev/null)" || [[ -z "$__saved" ]]; then
    while :; do
      printf '%s%s%s ' "$SEC_C_BWH" "$__prompt" "$SEC_C_RES" >/dev/tty
      IFS= read -rs __val </dev/tty || sec_die "input aborted"
      printf '\n' >/dev/tty
      [[ -n "$__val" ]] && break
      sec_warn "a value is required"
    done
    printf -v "$__var" '%s' "$__val"
    return 0
  fi
  trap 'stty "$__saved" </dev/tty 2>/dev/null; printf "\n" >/dev/tty; sec_die "input aborted"' INT
  while :; do
    printf '%s%s%s ' "$SEC_C_BWH" "$__prompt" "$SEC_C_RES" >/dev/tty
    __val=""
    stty -echo -icanon min 1 time 0 </dev/tty
    while IFS= read -rk 1 __ch </dev/tty; do
      case "$__ch" in
        $'\n'|$'\r') break ;;
        $'\177'|$'\b')                       # Backspace / Delete
          (( ${#__val} )) && { __val="${__val[1,-2]}"; printf '\b \b' >/dev/tty; } ;;
        $'\025')                             # ^U — clear the whole entry
          while (( ${#__val} )); do __val="${__val[1,-2]}"; printf '\b \b' >/dev/tty; done ;;
        *) __val+="$__ch"; printf '*' >/dev/tty ;;
      esac
    done
    stty "$__saved" </dev/tty
    printf '\n' >/dev/tty
    [[ -n "$__val" ]] && break
    sec_warn "a value is required"
  done
  trap - INT
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

# sec_write_human_fragment <slot> <NAME=op://ref>... — cache after materializing.
# References are op:// only (no SOPS, no ciphertext). On first materialization, or
# when the reference set changes, the template resolves refs with direct `op read`
# calls. Steady-state applies reuse the already-rendered 0600 fragment so routine
# chezmoi operations do not cross the Touch ID boundary.
sec_write_human_fragment() {
  local slot="$1"; shift
  local frag pair name ref sig
  frag="$(sec_fragment_path "$slot")"
  sig="$(printf '%s\n' "$@" | shasum -a 256 | cut -d ' ' -f 1)"
  mkdir -p "${frag:h}"
  {
    cat <<EOF
{{- /* human slot ${slot}: cached after first materialization; set CHEZMOI_REFRESH_SECRETS=1 to force 1Password resolution. */ -}}
{{- \$target := joinPath .chezmoi.homeDir ".config" "zsh" "secrets.d" "${slot}.sh" -}}
{{- \$cacheHeader := "# chezmoi: op-cache-v1 ${sig}" -}}
{{- \$cachedHeader := "" -}}
{{- if stat \$target -}}{{ \$cachedHeader = output "sh" "-c" (printf "sed -n '1p' %q" \$target) | trim }}{{- end -}}
{{- if and (ne (env "CHEZMOI_REFRESH_SECRETS") "1") (eq \$cachedHeader \$cacheHeader) -}}
{{ output "cat" \$target -}}
{{- else -}}
# chezmoi: op-cache-v1 ${sig}
EOF
    for pair in "$@"; do
      name="${pair%%=*}"
      ref="${pair#*=}"
      printf 'export %s="{{ output "op" "read" "--no-newline" "%s" }}"\n' "$name" "$ref"
    done
    printf '%s\n' "{{ end -}}"
  } >"$frag"
}

# ---------------------------------------------------------------------------
# 1Password helpers (human machines). The operator's service-account token is
# the single mechanism: `system-onboard`/`system-secrets` run `op` in
# SERVICE-ACCOUNT mode by prefixing each call with the token, so there is no
# desktop-app authorization and no account picker (a service account is bound to
# one account; its vault list is already scoped). This lets the tooling CREATE
# the backing item from a masked value and derive its op:// reference, and it is
# the same token copied to each new machine for apply-time resolution.
#
# Source of truth: a RAW token string at $OP_SA_TOKEN_FILE — loose, 0600, NEVER
# committed, and deliberately NOT under ~/.config/zsh/secrets.d (which every shell
# sources). environment.sh exports it ONLY over SSH, so a LOCAL `chezmoi apply`
# has no token and resolves op:// in account mode (Touch ID, full Private-vault
# access for the GPG import), while an SSH apply gets the token and uses service
# mode. The token is passed as a one-shot ENV assignment (env, not argv — not
# visible in process args). Items use the "API Credential" category; values are
# stored ONE PER MACHINE as a CONCEALED field labeled with the slot hash, so refs
# are deterministic: op://<vault>/<NAME>/<slot-hash> (one item per variable, one
# field per machine — per-machine values and per-machine rotation).
# ---------------------------------------------------------------------------
OP_SA_TOKEN_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/op/service-account"

sec_op_available() { command -v op >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }
sec_op_have_token() { [[ -s "$OP_SA_TOKEN_FILE" ]]; }

# sec_op <args…> — run op in service-account mode using the loose token.
sec_op() { OP_SERVICE_ACCOUNT_TOKEN="$(cat "$OP_SA_TOKEN_FILE")" op "$@"; }

# sec_op_store_token <token> — write the raw token loose at 0600.
sec_op_store_token() {
  ( umask 077; mkdir -p "${OP_SA_TOKEN_FILE:h}" && printf '%s' "$1" >"$OP_SA_TOKEN_FILE" ) \
    || sec_die "could not write $OP_SA_TOKEN_FILE"
  chmod 600 "$OP_SA_TOKEN_FILE"
}

# sec_op_read_ref <op://ref> — read a value via the 1Password app in ACCOUNT
# mode (env -u OP_SERVICE_ACCOUNT_TOKEN, so a half-set token can't force the SA
# and loop). Echoes the value; empty + nonzero on failure.
sec_op_read_ref() { env -u OP_SERVICE_ACCOUNT_TOKEN op read "$1" 2>/dev/null; }

# sec_op_ensure_token — guarantee the loose token exists. In order:
#   1. token file already present                        -> done
#   2. a remembered op:// ref ($OP_SA_TOKEN_FILE.ref) read via the desktop app
#   3. prompt for the op:// ref, read it via the desktop app, then remember it
#   4. masked paste of the raw token
# Reads always go through the desktop app (account mode), since the service
# account itself can't be expected to store its own token.
sec_op_ensure_token() {
  sec_op_have_token && return 0
  local ref_file="$OP_SA_TOKEN_FILE.ref" __tok="" __ref=""

  # 2. remembered ref (non-interactive; just needs the app authed)
  if command -v op >/dev/null 2>&1 && [[ -s "$ref_file" ]]; then
    __ref="$(cat "$ref_file")"
    if __tok="$(sec_op_read_ref "$__ref")" && [[ -n "$__tok" ]]; then
      sec_op_store_token "$__tok"; __tok=""
      sec_ok "loaded service-account token from $__ref (account mode) at $OP_SA_TOKEN_FILE"
      return 0
    fi
    sec_warn "could not read $__ref via the 1Password app; will prompt"
  fi

  # 3. prompt for a ref and read it via the desktop app
  if command -v op >/dev/null 2>&1 && sec_have_tty; then
    prompt_default __ref \
      "1Password op:// ref for the service-account token (e.g. op://<vault>/<item>/credential; blank to paste)" \
      ""
    if [[ -n "$__ref" ]]; then
      if __tok="$(sec_op_read_ref "$__ref")" && [[ -n "$__tok" ]]; then
        sec_op_store_token "$__tok"; __tok=""
        ( umask 077; printf '%s' "$__ref" >"$ref_file" ) && chmod 600 "$ref_file"
        sec_ok "stored service-account token from $__ref (loose, 0600) at $OP_SA_TOKEN_FILE"
        return 0
      fi
      sec_warn "could not read $__ref; falling back to paste"
    fi
  fi

  # 4. masked paste
  prompt_secret __tok "1Password service-account token (stored at $OP_SA_TOKEN_FILE):"
  sec_op_store_token "$__tok"; __tok=""
  sec_ok "stored service-account token (loose, 0600) at $OP_SA_TOKEN_FILE"
}

# sec_op_item_exists <vault> <title>
sec_op_item_exists() { sec_op item get "$2" --vault "$1" >/dev/null 2>&1; }

# sec_op_field_exists <vault> <item> <field-label> — 0 iff the field already
# resolves to a value (the item exists and carries that slot's field).
sec_op_field_exists() { sec_op read "op://$1/$2/$3" >/dev/null 2>&1; }

# sec_op_upsert_field <vault> <item> <field-label> <value>
# Store <value> as a CONCEALED field labeled <field-label> on the item (one item
# per variable; one field per machine, keyed by the slot hash). Creates the item
# (API Credential category) if absent, else edits it in place. The value is fed
# via a JSON template on STDIN, never argv (so it is not visible to `ps`). Echoes
# the resulting op:// reference.
sec_op_upsert_field() {
  local vault="$1" item="$2" field="$3" value="$4" cur merged
  if sec_op_item_exists "$vault" "$item"; then
    # Merge into the FULL current item. A partial {fields:[…]} template makes
    # `op item edit` REPLACE the field set (wiping other machines' fields), so
    # fetch the item, drop any same-labeled field, append ours, and write it back.
    cur="$(sec_op item get "$item" --vault "$vault" --format json 2>/dev/null)" || return 1
    merged="$(printf '%s' "$cur" | __OP_VAL="$value" jq --arg f "$field" \
      '.fields = ((.fields // [] | map(select(.label != $f and .id != $f)))
                  + [{label: $f, type: "CONCEALED", value: $ENV.__OP_VAL}])')" || return 1
    printf '%s' "$merged" | sec_op item edit "$item" --vault "$vault" - >/dev/null 2>&1 \
      || return 1
  else
    __OP_VAL="$value" jq -n --arg t "$item" --arg f "$field" \
      '{title: $t, category: "API_CREDENTIAL",
        fields: [{label: $f, type: "CONCEALED", value: $ENV.__OP_VAL}]}' \
      | sec_op item create --vault "$vault" - >/dev/null 2>&1 \
      || return 1
  fi
  printf 'op://%s/%s/%s\n' "$vault" "$item" "$field"
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
    # Human: each secret resolves from 1Password at apply via `output "op" read`.
    # Schema: ONE item per variable; ONE concealed field per machine, labeled
    # with the slot hash — so the ref is deterministic op://<vault>/<NAME>/<hash>.
    # With op + jq we read/write those fields through the service-account token
    # (SA mode). Without op/jq, fall back to entering op:// references by hand.
    local pairs=() vault="" desc hash="${slot#slot-}"
    if sec_op_available; then
      sec_op_ensure_token
      local -a vaults
      vaults=("${(@f)$(sec_op vault list --format=json 2>/dev/null | jq -r '.[].name')}")
      vaults=(${vaults:#})
      if (( ${#vaults[@]} > 1 )); then
        prompt_choice vault "1Password vault" "${vaults[@]}"
      elif (( ${#vaults[@]} == 1 )); then
        vault="${vaults[1]}"
      fi
    fi
    sec_info "1Password setup for the '$profile' secrets (human slot $slot, field $hash)."
    [[ -n "$vault" ]] \
      && sec_warn "op:// references are committed to this PUBLIC repo — keep vault/item names non-identifying."
    for n in "${names[@]}"; do
      desc="$(sec_manifest_prompt "$n")"
      if [[ -n "$vault" ]]; then
        ref="op://$vault/$n/$hash"
        if sec_op_field_exists "$vault" "$n" "$hash"; then
          if confirm "  $n ($desc): field $hash already set — replace its value?"; then
            prompt_secret val "    new value for $n (masked):"
            sec_op_upsert_field "$vault" "$n" "$hash" "$val" >/dev/null \
              || sec_die "could not update $ref (does the service account have write access to '$vault'?)"
            val=""; sec_ok "    updated $ref"
          else
            sec_info "    keeping existing $ref"
          fi
        else
          prompt_secret val "  $n ($desc) — value for field $hash (masked):"
          sec_op_upsert_field "$vault" "$n" "$hash" "$val" >/dev/null \
            || sec_die "could not write $ref (does the service account have write access to '$vault'?)"
          val=""; sec_ok "    wrote $ref"
        fi
      else
        prompt_required ref "  $n — op:// reference ($desc):"
      fi
      pairs+=("$n=$ref")
    done
    sec_write_human_fragment "$slot" "${pairs[@]}"
    sec_ok "wrote ${#pairs[@]} 1Password reference(s) for slot $slot"
  fi
}

# sec_commit_paths_for_slot <slot> — the committed paths a slot touches.
sec_commit_paths_for_slot() {
  local slot="$1"
  printf '%s\n' \
    "$(sec_fragment_path "$slot")" \
    "$SOPS_YAML" \
    "$MANIFEST"
  # Human slots have no SOPS blob; guard with `if` (not a trailing `&&`, whose
  # false result would make this function return 1 and trip the caller's `set
  # -e` during `paths=("$(...)")`).
  if [[ -f "$(sec_blob_path "$slot")" ]]; then
    printf '%s\n' "$(sec_blob_path "$slot")"
  fi
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
