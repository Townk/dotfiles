# system-secrets-common.zsh — shared helpers for `system-onboard` and
# `system-secrets`. Intended to be sourced; does not run on its own.
#
# Both commands share this library so the onboarding path and the later
# add/rotate path cannot drift in how they name slots, render fragments,
# encrypt blobs, or audit for leaks. Mirrors the system-package-common.zsh
# pattern.
#
# HARD CONSTRAINT (this repo is PUBLIC): committed artifacts use OPAQUE SLOT
# IDS only — never a machine alias, hostname, username, or work tool name.
# Real endpoints and the alias<->slot map live in the loose, unmanaged layer
# (~/.ssh/config.d/*, the operator map). Every commit path runs sec::leak_audit.

# ---------------------------------------------------------------------------
# Logging, the ANSI palette (C_*), help-token dispatch, and require_cmd come
# from the shared base. Source it relative to THIS file so it resolves both at
# ~/.local/lib (production) and at the repo path.
# ---------------------------------------------------------------------------
_sec_common_self="${(%):-%x}"
source "$(dirname "$_sec_common_self")/common.zsh"
unset _sec_common_self

# ---------------------------------------------------------------------------
# Repository paths. Resolves the chezmoi source dir, the git work tree (repo
# root), and every secret-related path relative to them. The repo root is the
# parent of the chezmoi source dir (.chezmoiroot = home).
# ---------------------------------------------------------------------------
sec::repo_paths() {
  SECRETS_SRC_DIR="$(chezmoi source-path)" ||
    die "cannot resolve chezmoi source path (is chezmoi installed?)"
  REPO_ROOT="$(git -C "$SECRETS_SRC_DIR" rev-parse --show-toplevel)" ||
    die "chezmoi source dir is not a git work tree: $SECRETS_SRC_DIR"
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
sec::manifest_check() {
  [[ -r "$MANIFEST" ]] || die "secrets manifest not found: $MANIFEST"
}

# sec::manifest_names — every declared secret name, one per line.
sec::manifest_names() {
  sec::manifest_check
  yq -r '.secrets[].name' "$MANIFEST"
}

# sec::manifest_names_for_profile <profile> — names whose requiredFor includes
# <profile>, one per line.
sec::manifest_names_for_profile() {
  sec::manifest_check
  profile="$1" yq -r \
    '.secrets[] | select(.requiredFor[] == strenv(profile)) | .name' \
    "$MANIFEST"
}

# sec::manifest_prompt <name> — the human prompt for a secret.
sec::manifest_prompt() {
  sec::manifest_check
  name="$1" yq -r \
    '.secrets[] | select(.name == strenv(name)) | .prompt' \
    "$MANIFEST"
}

# sec::manifest_has <name> — return 0 iff the secret is declared.
sec::manifest_has() {
  sec::manifest_check
  local hit
  hit="$(name="$1" yq -r \
    '[.secrets[] | select(.name == strenv(name))] | length' "$MANIFEST")"
  [[ "$hit" != "0" ]]
}

# sec::manifest_add <name> <prompt> <comma-separated-profiles> — append a new
# secret entry to the manifest. Caller has already validated name/profiles.
sec::manifest_add() {
  sec::manifest_check
  name="$1" pr="$2" profs="${3// /}" yq -i '
    .secrets += [{
      "name": strenv(name),
      "prompt": strenv(pr),
      "requiredFor": (strenv(profs) | split(","))
    }]' "$MANIFEST"
}

# sec::manifest_add_profile <name> <profile> — add <profile> to a declared
# secret's requiredFor if absent. Returns 0 iff it actually added it (so callers
# can log/commit), 1 if the profile was already present.
sec::manifest_add_profile() {
  sec::manifest_check
  local name="$1" profile="$2" has
  has="$(name="$name" p="$profile" yq -r \
    '.secrets[] | select(.name == strenv(name)) | (.requiredFor | contains([strenv(p)]))' \
    "$MANIFEST")"
  [[ "$has" == "true" ]] && return 1
  name="$name" p="$profile" yq -i '
    (.secrets[] | select(.name == strenv(name)) | .requiredFor) += [strenv(p)]
  ' "$MANIFEST"
  return 0
}

# ---------------------------------------------------------------------------
# Interactive prompt helpers (prompt::required / ::default / ::secret /
# ::choice / ::confirm) live in the shared prompt-common.zsh module.
# ---------------------------------------------------------------------------
_sec_prompt_self="${(%):-%x}"
source "$(dirname "$_sec_prompt_self")/prompt-common.zsh"
unset _sec_prompt_self

# ---------------------------------------------------------------------------
# Slot ids and slot-derived paths.
# ---------------------------------------------------------------------------
# sec::gen_slot — emit a fresh opaque slot id: slot-<6 hex>. Non-identifying.
# Reads a fixed 4 bytes (no producer-side SIGPIPE under pipefail) and keeps 6
# hex chars. Not crypto-grade; collisions are caught against the operator map.
sec::gen_slot() {
  local hex
  hex="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-6)"
  [[ ${#hex} -eq 6 ]] || hex="$(printf '%06x' $(((RANDOM * 65536 + RANDOM) % 16777216)))"
  printf 'slot-%s' "$hex"
}

# sec::valid_slot <slot> — return 0 iff slot matches the opaque-id shape.
sec::valid_slot() {
  [[ "$1" == slot-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9] ]]
}

# sec::valid_name <name> — return 0 iff <name> is a valid env var name.
sec::valid_name() { [[ "$1" =~ '^[A-Z][A-Z0-9_]*$' ]]; }

sec::fragment_path() { printf '%s/private_%s.sh.tmpl' "$FRAGMENT_DIR" "$1"; }
# Per-secret encrypted blobs live under secrets/<slot>/<NAME>.sops.sh so a single
# secret can be added or rotated without re-encrypting the slot's whole set.
sec::blob_dir() { printf '%s/%s' "$SECRETS_BLOB_DIR" "$1"; }
sec::blob_path() { printf '%s/%s/%s.sops.sh' "$SECRETS_BLOB_DIR" "$1" "$2"; }
# Pre-split layout: one monolithic blob per slot. Retained ONLY for lazy-migration
# detection — the operator holds a headless box's PUBLIC key, so it cannot decrypt
# an old blob to split it; the first per-secret edit re-collects the slot's values
# once and drops this file. New blobs never use this path.
sec::legacy_blob_path() { printf '%s/%s.sops.sh' "$SECRETS_BLOB_DIR" "$1"; }
# sec::headless_slot_names <slot> — NAMEs that currently have a per-secret blob,
# one per line (the set the fragment must decrypt). Empty when none yet.
sec::headless_slot_names() {
  local dir b
  dir="$(sec::blob_dir "$1")"
  [[ -d "$dir" ]] || return 0
  for b in "$dir"/*.sops.sh(N); do
    printf '%s\n' "${${b:t}%.sops.sh}"
  done
}

# ---------------------------------------------------------------------------
# Operator map — LOOSE, NEVER COMMITTED. Lives under ~/.config/chezmoi/.
# Maps each opaque slot to the operator-only facts needed to manage it:
#   <slot>: { alias, profile, kind, recipient }
# alias/host are the leak-sensitive bits and stay here, off git.
# ---------------------------------------------------------------------------
sec::map_init() {
  if [[ ! -f "$OPERATOR_MAP" ]]; then
    mkdir -p "${OPERATOR_MAP:h}"
    printf '{}\n' >"$OPERATOR_MAP"
    chmod 0600 "$OPERATOR_MAP"
  fi
}

# sec::map_get <slot> <field> — print a field value (empty if unset). Read-only:
# never creates the map (so --dry-run has no side effects).
sec::map_get() {
  [[ -f "$OPERATOR_MAP" ]] || {
    printf ''
    return 0
  }
  slot="$1" field="$2" yq -r \
    '.[strenv(slot)][strenv(field)] // ""' "$OPERATOR_MAP"
}

# sec::map_set <slot> <alias> <profile> <kind> <recipient>
# MERGE over any existing entry (`(… // {}) * {…}`) rather than replacing it, so
# extra fields written elsewhere — e.g. a `color` window-tint set via
# sec::map_set_color — survive a re-onboard. The four managed fields are always
# overwritten with the new values.
sec::map_set() {
  sec::map_init
  slot="$1" alias="$2" profile="$3" kind="$4" recipient="$5" yq -i '
    .[strenv(slot)] = ((.[strenv(slot)] // {}) * {
      "alias": strenv(alias),
      "profile": strenv(profile),
      "kind": strenv(kind),
      "recipient": strenv(recipient)
    })' "$OPERATOR_MAP"
}

# sec::map_set_color <slot> <color> — set the optional per-machine window-tint
# color (a palette name the terminal-mux WezTerm integration reads to tint a
# session's background). Loose-map only, never committed; an unknown name simply
# falls back to grey downstream, so this does not validate against the palette.
sec::map_set_color() {
  sec::map_init
  slot="$1" color="$2" yq -i '.[strenv(slot)].color = strenv(color)' "$OPERATOR_MAP"
}

# sec::map_clear_color <slot> — remove the optional window-tint color, reverting
# the machine to its profile default downstream. No-op if the slot has none.
sec::map_clear_color() {
  [[ -f "$OPERATOR_MAP" ]] || return 0
  slot="$1" yq -i 'del(.[strenv(slot)].color)' "$OPERATOR_MAP"
}

# ---------------------------------------------------------------------------
# Rotation stamp (HI-10). A human slot's cache signature (see
# sec::write_human_fragment) is computed from the name=ref pairs ALONE, but a
# rotate changes the 1Password VALUE while leaving the ref set byte-identical:
# the regenerated fragment matched the old sig, the commit was empty, and every
# OTHER machine's next apply hit its op-cache and re-emitted the STALE value. So
# a rotated/compromised credential never propagated. We fold a per-slot,
# monotonically-increasing rotation stamp into the sig: a rotate advances it,
# which changes the committed fragment, so every target's next apply misses its
# cache and re-resolves the NEW value. A normal apply (no rotation) leaves the
# stamp — and thus the sig — untouched, so the Touch-ID-avoiding cache still hits.
# The stamp lives in the loose operator map (unmanaged) as the slot's `rotated`
# field; sec::map_set MERGES, so it survives a re-onboard just like `color`.
# ---------------------------------------------------------------------------
# sec::rotation_stamp <slot> — the slot's rotation stamp (empty if never rotated).
sec::rotation_stamp() { sec::map_get "$1" rotated; }

# sec::set_rotation_stamp <slot> <stamp> — persist the rotation stamp (loose map).
sec::set_rotation_stamp() {
  sec::map_init
  slot="$1" stamp="$2" yq -i '.[strenv(slot)].rotated = strenv(stamp)' "$OPERATOR_MAP"
}

# sec::bump_rotation_stamp <slot> — advance the stamp to the wall clock, forced
# STRICTLY greater than any prior value so two rotations in the same second still
# produce distinct sigs (EPOCHSECONDS needs zsh/datetime; `date +%s` is portable).
sec::bump_rotation_stamp() {
  local prev now
  prev="$(sec::rotation_stamp "$1")"
  now="$(date +%s)"
  [[ -n "$prev" && "$prev" -ge "$now" ]] && now=$((prev + 1))
  sec::set_rotation_stamp "$1" "$now"
}

# sec::map_slot_for_alias <alias> — print the slot mapped to <alias> (or empty).
# Read-only: never creates the map.
sec::map_slot_for_alias() {
  [[ -f "$OPERATOR_MAP" ]] || {
    printf ''
    return 0
  }
  alias="$1" yq -r \
    'to_entries | map(select(.value.alias == strenv(alias))) | .[0].key // ""' \
    "$OPERATOR_MAP"
}

# ---------------------------------------------------------------------------
# SOPS + age. Blobs are BINARY-store sops files at secrets/<slot>/<NAME>.sops.sh
# (one per variable), whose decrypted bytes are a ready-to-source
# `export NAME=value` line — shell quoting is done here (in shell), so the
# decrypt template is a verbatim passthrough. The .sops.yaml creation rule is
# dir-wide per slot (secrets/<slot>/.*\.sops\.sh$ -> recipient) so every one of a
# slot's blobs shares one rule and `sops updatekeys`/review work; the recipient is
# passed explicitly to encrypt so it never depends on cwd.
# ---------------------------------------------------------------------------

# sec::sops_rule_set <slot> <recipient> — upsert the slot's (dir-wide) rule.
sec::sops_rule_set() {
  local slot="$1" recipient="$2"
  [[ -f "$SOPS_YAML" ]] || printf 'creation_rules: []\n' >"$SOPS_YAML"
  re="secrets/${slot}/.*\\.sops\\.sh\$" age="$recipient" yq -i '
    .creation_rules = ((.creation_rules // [])
      | map(select(.path_regex != strenv(re)))
      + [{"path_regex": strenv(re), "age": strenv(age)}])
  ' "$SOPS_YAML"
}

# sec::sops_rule_remove_legacy <slot> — drop the pre-split monolithic rule
# (secrets/<slot>.sops.sh$) once per-secret blobs replace it. No-op if absent.
sec::sops_rule_remove_legacy() {
  [[ -f "$SOPS_YAML" ]] || return 0
  re="secrets/${1}\\.sops\\.sh\$" yq -i \
    '.creation_rules = ((.creation_rules // []) | map(select(.path_regex != strenv(re))))' \
    "$SOPS_YAML"
}

# sec::sops_recipient_for_slot <slot> — recipient from .sops.yaml (or empty).
# Matches both the new dir-wide rule and the legacy monolithic rule.
sec::sops_recipient_for_slot() {
  [[ -f "$SOPS_YAML" ]] || {
    printf ''
    return 0
  }
  rn="secrets/${1}/.*\\.sops\\.sh\$" ro="secrets/${1}\\.sops\\.sh\$" yq -r \
    '(.creation_rules // [])[] | select(.path_regex == strenv(rn) or .path_regex == strenv(ro)) | .age' \
    "$SOPS_YAML" 2>/dev/null | head -n1
}

# sec::sops_encrypt <recipient> <plaintext_file> <blob_path>
# Encrypt to a temp file first, then move into place, so a failure never leaves
# a partial or plaintext blob at the destination.
sec::sops_encrypt() {
  local recipient="$1" plain="$2" blob="$3" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/sec-blob.XXXXXX")"
  # --config /dev/null: encrypt to the explicit recipient and ignore the repo
  # .sops.yaml (whose creation rules match the blob path, not this temp input).
  # .sops.yaml stays the committed mirror used by `sops updatekeys`/review.
  if ! sops --config /dev/null --encrypt --age "$recipient" \
    --input-type binary --output-type binary "$plain" >"$tmp"; then
    rm -f "$tmp"
    die "sops encryption failed for recipient $recipient"
  fi
  mv "$tmp" "$blob"
}

# ---------------------------------------------------------------------------
# Fragment template writers. Each writes home/.../private_secrets.d/
# private_<slot>.sh.tmpl, which chezmoi renders to ~/.config/zsh/secrets.d/
# <slot>.sh (0600) only on the host whose secretsSlot matches (.chezmoiignore).
# ---------------------------------------------------------------------------

# sec::write_headless_fragment <slot> <name>... — body is one SOPS decrypt call
# per variable. The ciphertext blobs live at repo-root secrets/<slot>/<NAME>.sops.sh
# (outside the chezmoi source root), each decrypting to a single `export` line.
sec::write_headless_fragment() {
  local slot="$1"
  shift
  local frag name
  frag="$(sec::fragment_path "$slot")"
  mkdir -p "${frag:h}"
  {
    cat <<EOF
{{- /* headless slot ${slot}: SOPS+age secrets, decrypted ONCE per apply into a
       0600 file (the private_ source prefix). One ciphertext blob per variable
       at repo-root secrets/${slot}/<NAME>.sops.sh, outside the chezmoi source
       root, so each is read by path and never rendered into \$HOME. sops finds
       the age identity through SOPS_AGE_KEY_FILE, set in chezmoi's [env] on
       headless hosts. Each blob decrypts to a single \`export NAME=value\`. */ -}}
EOF
    for name in "$@"; do
      printf '{{ output "sops" "--decrypt" (joinPath .chezmoi.sourceDir ".." "secrets" "%s" "%s.sops.sh") }}\n' \
        "$slot" "$name"
    done
  } >"$frag"
}

# sec::write_human_fragment <slot> <NAME=op://ref>... — cache after materializing.
# References are op:// only (no SOPS, no ciphertext). On first materialization, or
# when the reference set changes, the template resolves refs with direct `op read`
# calls. Steady-state applies reuse the already-rendered 0600 fragment so routine
# chezmoi operations do not cross the Touch ID boundary.
sec::write_human_fragment() {
  local slot="$1"
  shift
  local frag pair name ref sig stamp
  frag="$(sec::fragment_path "$slot")"
  # HI-10: fold the slot's rotation stamp into the sig so a rotate (which leaves
  # the name=ref set unchanged) still changes the sig, invalidating every
  # target's op-cache; an unrotated slot keeps a stable stamp, so the sig — and
  # the cache hit — is unchanged. Empty stamp for a never-rotated slot.
  stamp="$(sec::rotation_stamp "$slot")"
  sig="$(printf '%s\n' "$stamp" "$@" | shasum -a 256 | cut -d ' ' -f 1)"
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
      # Single-quote the assignment so $, backtick, and \ in the resolved value
      # are inert; the Go-template `replace` turns each embedded ' into '"'"' so
      # a value with a single quote still closes/reopens cleanly (SEC-1).
      printf 'export %s='\''{{ output "op" "read" "--no-newline" "%s" | replace "'\''" "'\''\\"'\''\\"'\''" }}'\''\n' "$name" "$ref"
    done
    printf '%s\n' "{{ end -}}"
  } >"$frag"
}

# ---------------------------------------------------------------------------
# 1Password helpers (human machines). PROVISIONING (create/edit the backing
# items here) uses the same auth split as RESOLUTION (`op read` at apply): the
# desktop app in ACCOUNT mode (Touch ID) on a machine you sit at, and the loose
# SERVICE-ACCOUNT token only over SSH, where there is no GUI. So a local human
# machine needs no token at all — `sec::op` picks the mode from the environment
# (see sec::op_use_service), exactly mirroring environment.sh.
#
# Source of truth for the token: a RAW string at $OP_SA_TOKEN_FILE — loose, 0600,
# NEVER committed, and deliberately NOT under ~/.config/zsh/secrets.d (which every
# shell sources). environment.sh exports it ONLY over SSH, so a LOCAL `chezmoi
# apply` has no token and resolves op:// in account mode (Touch ID, full
# Private-vault access for the GPG import), while an SSH apply gets the token and
# uses service mode. The token is passed as a one-shot ENV assignment (env, not
# argv — not visible in process args). Items use the "API Credential" category;
# values are stored ONE PER MACHINE as a CONCEALED field labeled with the slot
# hash, so refs are deterministic: op://<vault>/<NAME>/<slot-hash> (one item per
# variable, one field per machine — per-machine values and per-machine rotation).
# ---------------------------------------------------------------------------
OP_SA_TOKEN_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/op/service-account"
# Cached 1Password vault name — loose, per-machine, NEVER committed. Kept in its
# own file (not the operator map) because known_slots() treats every top-level
# map key as a slot, so a non-slot key there would corrupt rotate/reconcile.
OP_VAULT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/op-vault"

sec::op_available() { command -v op >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }
sec::op_have_token() { [[ -s "$OP_SA_TOKEN_FILE" ]]; }

# sec::op_use_service — 0 iff op must use the loose service-account token instead
# of the desktop app: i.e. over SSH, where there is no GUI for Touch ID. Uses
# the canonical remote-detection triple (the identity of mux::is_remote in
# mux-bootstrap.zsh) — a bare zsh lib cannot source that zsh layer, so the
# triple is inlined here; keep it in sync. This previously dropped SSH_TTY,
# which misclassified a no-pty `ssh -T` login as local (apply-time analog:
# environment.sh's over-SSH block).
sec::op_use_service() {
  [[ -n "${SSH_TTY:-}${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]
}

# sec::op_sa <args…> — force SERVICE-ACCOUNT mode using the loose token.
sec::op_sa() { OP_SERVICE_ACCOUNT_TOKEN="$(cat "$OP_SA_TOKEN_FILE")" op "$@"; }

# sec::op_account <args…> — force ACCOUNT mode (desktop app / Touch ID). `env -u`
# drops any half-set token so it can't hijack the call into the SA and loop.
sec::op_account() { env -u OP_SERVICE_ACCOUNT_TOKEN op "$@"; }

# sec::op <args…> — run op with the auth the environment calls for: service over
# SSH, account locally. All item reads/writes go through this.
sec::op() {
  if sec::op_use_service; then sec::op_sa "$@"; else sec::op_account "$@"; fi
}

# sec::op_token_valid — 0 iff the stored token actually authenticates. A
# non-empty file is NOT proof: a wrong value (e.g. a pasted secret, or a ref
# that points at the wrong item) reads fine but fails every SA call with
# "format is invalid". Always probes in SERVICE mode — it is the token being
# validated, not the desktop app.
sec::op_token_valid() {
  sec::op_have_token || return 1
  sec::op_sa vault list --format=json >/dev/null 2>&1
}

# sec::op_store_token <token> — write the raw token loose at 0600.
sec::op_store_token() {
  (
    umask 077
    mkdir -p "${OP_SA_TOKEN_FILE:h}" && printf '%s' "$1" >"$OP_SA_TOKEN_FILE"
  ) ||
    die "could not write $OP_SA_TOKEN_FILE"
  chmod 600 "$OP_SA_TOKEN_FILE"
}

# sec::op_vault_get — print the cached vault name (empty if none).
sec::op_vault_get() { [[ -r "$OP_VAULT_FILE" ]] && cat "$OP_VAULT_FILE" || printf ''; }

# sec::op_vault_set <name> — remember the chosen vault (loose, 0600).
sec::op_vault_set() {
  (
    umask 077
    mkdir -p "${OP_VAULT_FILE:h}" && printf '%s' "$1" >"$OP_VAULT_FILE"
  ) ||
    die "could not write $OP_VAULT_FILE"
  chmod 600 "$OP_VAULT_FILE"
}

# sec::op_read_ref <op://ref> — read a value via the 1Password app in ACCOUNT
# mode (env -u OP_SERVICE_ACCOUNT_TOKEN, so a half-set token can't force the SA
# and loop). Echoes the value; empty + nonzero on failure.
sec::op_read_ref() { sec::op_account read "$1" 2>/dev/null; }

# sec::op_ensure_token — guarantee a VALID loose token exists (only needed over
# SSH; local machines use the desktop app). In order:
#   1. token file present AND authenticates                -> done
#   2. a remembered op:// ref ($OP_SA_TOKEN_FILE.ref) read via the desktop app
#   3. prompt for the op:// ref, read it via the desktop app, then remember it
#   4. masked paste of the raw token
# Reads always go through the desktop app (account mode), since the service
# account itself can't be expected to store its own token.
sec::op_ensure_token() {
  # A non-empty file is not a working token: validate it. If it is stale/wrong,
  # discard BOTH it and its remembered ref (the ref most likely pointed at the
  # wrong item) so the steps below re-collect from scratch.
  if sec::op_have_token; then
    sec::op_token_valid && return 0
    log_warn "stored service-account token at $OP_SA_TOKEN_FILE is invalid; discarding it and its remembered ref"
    rm -f "$OP_SA_TOKEN_FILE" "$OP_SA_TOKEN_FILE.ref"
  fi
  local ref_file="$OP_SA_TOKEN_FILE.ref" __tok="" __ref=""

  # 2. remembered ref (non-interactive; just needs the app authed)
  if command -v op >/dev/null 2>&1 && [[ -s "$ref_file" ]]; then
    __ref="$(cat "$ref_file")"
    if __tok="$(sec::op_read_ref "$__ref")" && [[ -n "$__tok" ]]; then
      sec::op_store_token "$__tok"
      __tok=""
      if sec::op_token_valid; then
        log_ok "loaded service-account token from $__ref (account mode) at $OP_SA_TOKEN_FILE"
        return 0
      fi
      log_warn "$__ref did not yield a valid service-account token; discarding it and will prompt"
      rm -f "$OP_SA_TOKEN_FILE" "$ref_file"
    else
      log_warn "could not read $__ref via the 1Password app; will prompt"
    fi
  fi

  # 3. prompt for a ref and read it via the desktop app
  if command -v op >/dev/null 2>&1 && have_tty; then
    prompt::default __ref \
      "1Password op:// ref for the service-account token (e.g. op://<vault>/<item>/credential; blank to paste)" \
      ""
    if [[ -n "$__ref" ]]; then
      if __tok="$(sec::op_read_ref "$__ref")" && [[ -n "$__tok" ]]; then
        sec::op_store_token "$__tok"
        __tok=""
        if sec::op_token_valid; then
          (
            umask 077
            printf '%s' "$__ref" >"$ref_file"
          ) && chmod 600 "$ref_file"
          log_ok "stored service-account token from $__ref (loose, 0600) at $OP_SA_TOKEN_FILE"
          return 0
        fi
        log_warn "$__ref resolves to a value but not a valid service-account token; falling back to paste"
        rm -f "$OP_SA_TOKEN_FILE"
      else
        log_warn "could not read $__ref; falling back to paste"
      fi
    fi
  fi

  # 4. masked paste
  prompt::secret __tok "1Password service-account token (stored at $OP_SA_TOKEN_FILE):"
  sec::op_store_token "$__tok"
  __tok=""
  sec::op_token_valid || {
    rm -f "$OP_SA_TOKEN_FILE"
    die "that value is not a valid 1Password service-account token (an SA token looks like 'ops_...'); nothing stored"
  }
  log_ok "stored service-account token (loose, 0600) at $OP_SA_TOKEN_FILE"
}

# sec::op_item_exists <vault> <title>
sec::op_item_exists() { sec::op item get "$2" --vault "$1" >/dev/null 2>&1; }

# sec::op_field_exists <vault> <item> <field-label> — 0 iff the field already
# resolves to a value (the item exists and carries that slot's field).
sec::op_field_exists() { sec::op read "op://$1/$2/$3" >/dev/null 2>&1; }

# sec::op_upsert_field <vault> <item> <field-label> <value>
# Store <value> as a CONCEALED field labeled <field-label> on the item (one item
# per variable; one field per machine, keyed by the slot hash). Creates the item
# (API Credential category) if absent, else edits it in place. The value is fed
# via a JSON template on STDIN, never argv (so it is not visible to `ps`). Echoes
# the resulting op:// reference.
sec::op_upsert_field() {
  local vault="$1" item="$2" field="$3" value="$4" cur merged
  if sec::op_item_exists "$vault" "$item"; then
    # Merge into the FULL current item. A partial {fields:[…]} template makes
    # `op item edit` REPLACE the field set (wiping other machines' fields), so
    # fetch the item, drop any same-labeled field, append ours, and write it back.
    cur="$(sec::op item get "$item" --vault "$vault" --format json 2>/dev/null)" || return 1
    merged="$(printf '%s' "$cur" | __OP_VAL="$value" jq --arg f "$field" \
      '.fields = ((.fields // [] | map(select(.label != $f and .id != $f)))
                  + [{label: $f, type: "CONCEALED", value: $ENV.__OP_VAL}])')" || return 1
    printf '%s' "$merged" | sec::op item edit "$item" --vault "$vault" - >/dev/null 2>&1 ||
      return 1
  else
    __OP_VAL="$value" jq -n --arg t "$item" --arg f "$field" \
      '{title: $t, category: "API_CREDENTIAL",
        fields: [{label: $f, type: "CONCEALED", value: $ENV.__OP_VAL}]}' |
      sec::op item create --vault "$vault" - >/dev/null 2>&1 ||
      return 1
  fi
  printf 'op://%s/%s/%s\n' "$vault" "$item" "$field"
}

# sec::op_resolve_vault — echo the 1Password vault to use, or empty when op/jq
# are unavailable (callers then fall back to manual op:// entry). Ensures a token
# over SSH, reuses the cached choice, or asks once and remembers it. Dies if the
# vault list fails. ALL informational output is routed to stderr so this stays
# safe inside a command substitution (only the vault name is written to stdout).
sec::op_resolve_vault() {
  sec::op_available || {
    printf ''
    return 0
  }
  sec::op_use_service && sec::op_ensure_token 1>&2
  local vault_json
  # Capture separately: piping op straight into an array command-substitution
  # with 2>/dev/null let an op auth failure die SILENTLY under pipefail.
  if ! vault_json="$(sec::op vault list --format=json 2>&1)"; then
    if sec::op_use_service; then
      die "1Password vault list failed (check the service-account token at $OP_SA_TOKEN_FILE): $vault_json"
    else
      die "1Password vault list failed — is the desktop app signed in? try 'op signin': $vault_json"
    fi
  fi
  local -a vaults
  vaults=("${(@f)$(printf '%s' "$vault_json" | jq -r '.[].name')}")
  vaults=(${vaults:#})
  local cached_vault vault=""
  cached_vault="$(sec::op_vault_get)"
  if [[ -n "$cached_vault" ]] && (($vaults[(Ie)$cached_vault])); then
    vault="$cached_vault"
    log_info "using cached 1Password vault '$vault' (clear $OP_VAULT_FILE to change)" 1>&2
  elif ((${#vaults[@]} > 1)); then
    prompt::choice vault "1Password vault" "${vaults[@]}"
    sec::op_vault_set "$vault"
  elif ((${#vaults[@]} == 1)); then
    vault="${vaults[1]}"
    sec::op_vault_set "$vault"
  fi
  printf '%s' "$vault"
}

# sec::op_set_field <vault> <name> <hash> <desc> — prompt for and store ONE
# machine's value for NAME (concealed field <hash> on item NAME). Confirms before
# replacing an existing value. Dies on write failure. Shared by full rebuild and
# single-secret add/rotate so both prompt and error identically.
sec::op_set_field() {
  local vault="$1" name="$2" hash="$3" desc="$4" val auth_hint ref="op://$1/$2/$3"
  if sec::op_use_service; then
    auth_hint="does the service account have write access to '$vault'?"
  else
    auth_hint="is the desktop app signed in with write access to '$vault'?"
  fi
  if sec::op_field_exists "$vault" "$name" "$hash"; then
    if prompt::confirm "  $name ($desc): field $hash already set — replace its value?"; then
      prompt::secret val "    new value for $name (masked):"
      sec::op_upsert_field "$vault" "$name" "$hash" "$val" >/dev/null ||
        die "could not update $ref ($auth_hint)"
      val=""
      # HI-10: a value actually changed — advance the slot's rotation stamp so
      # the regenerated fragment gets a fresh sig and every target re-resolves.
      sec::bump_rotation_stamp "slot-${hash}"
      log_ok "    updated $ref"
    else
      log_info "    keeping existing $ref"
    fi
  else
    prompt::secret val "  $name ($desc) — value for field $hash (masked):"
    sec::op_upsert_field "$vault" "$name" "$hash" "$val" >/dev/null ||
      die "could not write $ref ($auth_hint)"
    val=""
    # HI-10: first write of this field is also a value change — stamp the slot.
    sec::bump_rotation_stamp "slot-${hash}"
    log_ok "    wrote $ref"
  fi
}

# ---------------------------------------------------------------------------
# Leak audit. Mirrors the local pre-commit hook: scan STAGED added lines,
# staged file names, AND the commit author identity against the gitignored
# .leak-patterns. The identity matters because git falls back to
# user@<hostname>.local when no user.email is configured (fresh machine,
# bootstrap window) — a hostname would land in the repo through a field the
# diff scan never sees. Run this in-tool right before committing so a leak
# fails early with a clear message instead of being caught (more opaquely) by
# the hook. No patterns file -> allow.
# ---------------------------------------------------------------------------
sec::leak_audit() {
  [[ -r "$LEAK_PATTERNS" ]] || return 0
  local added names ident haystack pat hits=""
  added="$(git -C "$REPO_ROOT" diff --cached -U0 --no-color --diff-filter=AM |
    grep '^+' | grep -v '^+++' || true)"
  names="$(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACMR || true)"
  # Exactly what a commit would record (env overrides included); errors (e.g.
  # undetectable identity on a dotless hostname) fall through empty — the
  # commit itself will fail with git's own message.
  ident="$(git -C "$REPO_ROOT" var GIT_AUTHOR_IDENT 2>/dev/null || true)"
  haystack="$added
$names
$ident"
  [[ -n "${haystack//[[:space:]]/}" ]] || return 0
  while IFS= read -r pat; do
    case "$pat" in '' | \#*) continue ;; esac
    if printf '%s\n' "$haystack" | grep -iEq -- "$pat"; then
      hits="$hits  - $pat"$'\n'
    fi
  done <"$LEAK_PATTERNS"
  if [[ -n "$hits" ]]; then
    log_error "staged changes match work/company leak patterns:"
    printf '%s' "$hits" >&2
    die "move work-specific data to the loose/unmanaged layer; this repo is public."
  fi
}

# ---------------------------------------------------------------------------
# Slot (re)build & per-secret materialization — the shared core used by BOTH
# onboarding (new slot) and `system-secrets` add/rotate (existing slot), so the
# paths cannot drift. `sec::rebuild_slot` (re)collects the slot's WHOLE required
# set; `sec::materialize_secret` touches ONE variable. The caller commits.
#
# Headless note: the operator holds only the box's age PUBLIC key (recipient),
# never its private key. Per-secret blobs mean adding/rotating one variable only
# re-encrypts that variable. But a legacy MONOLITHIC blob cannot be split (no
# private key), so the first per-secret edit on such a slot re-collects the whole
# set once (lazy migration). Per-machine isolation is preserved: each blob is
# encrypted only to its own slot's recipient.
# ---------------------------------------------------------------------------

# sec::arm_plain_scrub <path> — arm traps that shred PATH (a decrypted-secret
# staging file or dir) on normal completion AND on every terminating signal.
# C1 (same root cause as prompt-common's MED-15, different site). Three zsh
# facts force this exact shape:
#   1. the EXIT trap does NOT run on SIGTERM, so a kill/timeout/supervisor TERM
#      during interactive entry would strand cleartext under $TMPDIR;
#   2. after a bare signal trap zsh RESUMES the interrupted code, so the signal
#      handler must scrub AND exit — falling back into the entry loop would
#      re-stage cleartext; and
#   3. prompt::secret installs then clears the shell's traps on every call (its
#      tty-restore teardown), which wipes any trap set before it — so callers
#      RE-ARM after each prompt, before any plaintext is written.
# PATH is expanded into the handlers NOW (not deref'd at signal time), so a trap
# still shreds the right path after the caller's locals go out of scope. Exit
# codes follow the 128+signal convention so the process still dies by signal.
sec::arm_plain_scrub() {
  local __p="$1"
  trap "rm -rf -- ${(q)__p}" EXIT
  trap "rm -rf -- ${(q)__p}; exit 130" INT
  trap "rm -rf -- ${(q)__p}; exit 143" TERM
  trap "rm -rf -- ${(q)__p}; exit 131" QUIT
  trap "rm -rf -- ${(q)__p}; exit 129" HUP
}

# sec::rebuild_slot <slot> — regenerate the fragment and the FULL per-secret blob
# set from freshly prompted values. Reads kind/profile/recipient from the map,
# and clears any legacy monolithic blob/rule it replaces.
sec::rebuild_slot() {
  local slot="$1" kind profile recipient
  kind="$(sec::map_get "$slot" kind)"
  profile="$(sec::map_get "$slot" profile)"
  [[ -n "$kind" && -n "$profile" ]] ||
    die "slot $slot is not in the operator map (run system-onboard first)"

  local names
  names=("${(@f)$(sec::manifest_names_for_profile "$profile")}")
  names=(${names:#})
  ((${#names[@]})) || {
    log_warn "manifest lists no secrets for profile '$profile'"
    return 0
  }

  local n val
  if [[ "$kind" == headless ]]; then
    recipient="$(sec::map_get "$slot" recipient)"
    [[ -n "$recipient" ]] || recipient="$(sec::sops_recipient_for_slot "$slot")"
    [[ -n "$recipient" ]] || die "no age recipient known for headless slot $slot"
    local tmpd
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sec-plain.XXXXXX")"
    chmod 0700 "$tmpd"
    sec::arm_plain_scrub "$tmpd"
    mkdir -p "$(sec::blob_dir "$slot")"
    sec::sops_rule_set "$slot" "$recipient"
    log_info "Enter values for the '$profile' secrets (hidden). Headless slot $slot:"
    for n in "${names[@]}"; do
      prompt::secret val "  $n — $(sec::manifest_prompt "$n"):"
      sec::arm_plain_scrub "$tmpd"   # re-arm: prompt::secret cleared the traps
      printf 'export %s=%s\n' "$n" "${(qq)val}" >"$tmpd/$n"
      val=""
      sec::sops_encrypt "$recipient" "$tmpd/$n" "$(sec::blob_path "$slot" "$n")"
    done
    rm -rf "$tmpd"
    trap - EXIT INT TERM QUIT HUP
    # A full rebuild is authoritative: drop any legacy monolithic blob/rule now
    # that per-secret blobs cover the set.
    [[ -f "$(sec::legacy_blob_path "$slot")" ]] && rm -f "$(sec::legacy_blob_path "$slot")"
    sec::sops_rule_remove_legacy "$slot"
    sec::write_headless_fragment "$slot" "${names[@]}"
    log_ok "encrypted ${#names[@]} secret(s) for slot $slot"
  else
    # Human: each secret resolves from 1Password at apply via `output "op" read`.
    # Schema: ONE item per variable; ONE concealed field per machine, labeled
    # with the slot hash — so the ref is deterministic op://<vault>/<NAME>/<hash>.
    # With op + jq we read/write those fields through `sec::op` (desktop app
    # locally, service-account token over SSH). Without op/jq, or with no vault,
    # fall back to entering op:// references by hand.
    local pairs=() vault desc ref hash="${slot#slot-}"
    vault="$(sec::op_resolve_vault)"
    log_info "1Password setup for the '$profile' secrets (human slot $slot, field $hash)."
    [[ -n "$vault" ]] &&
      log_warn "op:// references are committed to this PUBLIC repo — keep vault/item names non-identifying."
    for n in "${names[@]}"; do
      desc="$(sec::manifest_prompt "$n")"
      if [[ -n "$vault" ]]; then
        sec::op_set_field "$vault" "$n" "$hash" "$desc"
        ref="op://$vault/$n/$hash"
      else
        prompt::required ref "  $n — op:// reference ($desc):"
      fi
      pairs+=("$n=$ref")
    done
    sec::write_human_fragment "$slot" "${pairs[@]}"
    log_ok "wrote ${#pairs[@]} 1Password reference(s) for slot $slot"
  fi
}

# sec::materialize_secret <slot> <name> — set/rotate ONE variable on a slot,
# leaving the slot's other secrets untouched, then regenerate the fragment.
# Reads kind/profile from the map; the profile MUST require NAME (caller ensures
# this via the manifest). Headless slots still on a legacy monolithic blob escalate
# to a full rebuild once (lazy migration).
sec::materialize_secret() {
  local slot="$1" name="$2" kind profile
  kind="$(sec::map_get "$slot" kind)"
  profile="$(sec::map_get "$slot" profile)"
  [[ -n "$kind" && -n "$profile" ]] ||
    die "slot $slot is not in the operator map (run system-onboard first)"
  sec::manifest_names_for_profile "$profile" | grep -Fxq "$name" ||
    die "'$name' is not required for profile '$profile' (slot $slot)"

  if [[ "$kind" == headless ]]; then
    local recipient
    if [[ -f "$(sec::legacy_blob_path "$slot")" ]]; then
      log_info "slot $slot still uses a monolithic blob; re-collecting its values once to migrate to per-secret blobs"
      sec::rebuild_slot "$slot"
      return 0
    fi
    recipient="$(sec::map_get "$slot" recipient)"
    [[ -n "$recipient" ]] || recipient="$(sec::sops_recipient_for_slot "$slot")"
    [[ -n "$recipient" ]] || die "no age recipient known for headless slot $slot"
    local val plain
    plain="$(mktemp "${TMPDIR:-/tmp}/sec-plain.XXXXXX")"
    chmod 0600 "$plain"
    sec::arm_plain_scrub "$plain"
    prompt::secret val "  $name — $(sec::manifest_prompt "$name") (headless slot $slot):"
    sec::arm_plain_scrub "$plain" # re-arm: prompt::secret's local_traps restored
    # the caller's dispositions on return, and its own EXIT handler ran here
    printf 'export %s=%s\n' "$name" "${(qq)val}" >"$plain"
    val=""
    mkdir -p "$(sec::blob_dir "$slot")"
    sec::sops_rule_set "$slot" "$recipient"
    sec::sops_encrypt "$recipient" "$plain" "$(sec::blob_path "$slot" "$name")"
    rm -f "$plain"
    trap - EXIT INT TERM QUIT HUP
    local slot_names
    slot_names=("${(@f)$(sec::headless_slot_names "$slot")}")
    slot_names=(${slot_names:#})
    sec::write_headless_fragment "$slot" "${slot_names[@]}"
    log_ok "encrypted $name for slot $slot"
  else
    # Human: without op/jq (or a resolvable vault) there is no clean single-field
    # path, so fall back to a full rebuild (manual op:// entry for the whole set).
    local vault hash="${slot#slot-}"
    vault="$(sec::op_resolve_vault)"
    [[ -n "$vault" ]] || {
      log_info "no 1Password vault available; rebuilding the whole slot to enter references manually"
      sec::rebuild_slot "$slot"
      return 0
    }
    log_warn "op:// references are committed to this PUBLIC repo — keep vault/item names non-identifying."
    sec::op_set_field "$vault" "$name" "$hash" "$(sec::manifest_prompt "$name")"
    # Regenerate the fragment from every profile secret that has a field on this
    # machine, so existing entries survive and only NAME changed.
    local -a names pairs
    names=("${(@f)$(sec::manifest_names_for_profile "$profile")}")
    names=(${names:#})
    local n
    for n in "${names[@]}"; do
      sec::op_field_exists "$vault" "$n" "$hash" && pairs+=("$n=op://$vault/$n/$hash")
    done
    sec::write_human_fragment "$slot" "${pairs[@]}"
    log_ok "wrote ${#pairs[@]} 1Password reference(s) for slot $slot"
  fi
}

# sec::commit_paths_for_slot <slot> — the committed paths a slot touches.
sec::commit_paths_for_slot() {
  local slot="$1"
  printf '%s\n' \
    "$(sec::fragment_path "$slot")" \
    "$SOPS_YAML" \
    "$MANIFEST"
  # Headless slots carry SOPS blobs; stage the per-secret blob directory and the
  # legacy monolithic path (so its deletion is staged on migration). git add of a
  # missing/never-tracked path is a swallowed no-op in sec::git_commit. Human
  # slots emit neither. Guard with `if` (not a trailing `&&`, whose false result
  # would return 1 and trip the caller's `set -e` during `paths=("$(...)")`).
  if [[ "$(sec::map_get "$slot" kind)" == headless ]]; then
    printf '%s\n' \
      "$(sec::blob_dir "$slot")" \
      "$(sec::legacy_blob_path "$slot")"
  fi
}

# sec::git_commit <message> <path>... — stage paths (relative to repo root),
# run the leak audit, then commit. Refuses if nothing staged.
sec::git_commit() {
  local msg="$1"
  shift
  local p
  for p in "$@"; do
    git -C "$REPO_ROOT" add -- "$p" 2>/dev/null || true
  done
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    log_info "nothing to commit"
    return 0
  fi
  sec::leak_audit
  git -C "$REPO_ROOT" commit -m "$msg" >/dev/null ||
    die "git commit failed"
  log_ok "committed: $msg"
}
