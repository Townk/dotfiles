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
  GENERATIONS="$SECRETS_BLOB_DIR/generations.yaml"
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

# sec::manifest_requires <profile> <name> — 0 iff <name>'s requiredFor
# includes <profile>. Deliberately pipe-free: callers run under
# `set -o pipefail`, where `<producer> | grep -q` fails the whole pipeline
# when grep exits on an early match and SIGPIPEs the producer — the FIRST
# manifest entry could never rotate.
sec::manifest_requires() {
  local -a _names
  _names=("${(@f)$(sec::manifest_names_for_profile "$1")}")
  (( ${_names[(Ie)$2]} ))
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

# sec::manifest_remove_profile <name> <profile> — drop <profile> from a
# declared secret's requiredFor. Returns 0 iff it actually removed it (mirror
# of sec::manifest_add_profile), 1 if the profile was not present.
sec::manifest_remove_profile() {
  sec::manifest_check
  local name="$1" profile="$2" has
  has="$(name="$name" p="$profile" yq -r \
    '.secrets[] | select(.name == strenv(name)) | (.requiredFor | contains([strenv(p)]))' \
    "$MANIFEST")"
  [[ "$has" == "true" ]] || return 1
  name="$name" p="$profile" yq -i '
    (.secrets[] | select(.name == strenv(name)) | .requiredFor) |=
      map(select(. != strenv(p)))
  ' "$MANIFEST"
  return 0
}

# sec::manifest_remove <name> — delete the secret's manifest entry entirely.
sec::manifest_remove() {
  sec::manifest_check
  name="$1" yq -i '.secrets |= map(select(.name != strenv(name)))' "$MANIFEST"
}

# sec::manifest_profiles_for <name> — the requiredFor profiles, one per line.
sec::manifest_profiles_for() {
  sec::manifest_check
  name="$1" yq -r \
    '.secrets[] | select(.name == strenv(name)) | .requiredFor[]' "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Rotation broadcast. `rotate NAME` stamps the manifest entry with a committed
# `rotated:` epoch; each slot records the epoch it last COLLECTED a value in
# secrets/generations.yaml (committed — slot ids are opaque, and the slot→name
# mapping is already public via blob filenames and op:// refs). `sync` treats
# generation < rotated exactly like a missing value, so rotating a key on one
# machine makes every other machine whose profile uses it re-collect on its
# next sync. Epochs come from `date +%s`; absent values read as 0, so secrets
# never rotated (or collected pre-feature) broadcast nothing.
# ---------------------------------------------------------------------------

# sec::manifest_rotated <name> — the entry's rotated epoch (0 if never).
sec::manifest_rotated() {
  sec::manifest_check
  local r
  r="$(name="$1" yq -r \
    '.secrets[] | select(.name == strenv(name)) | .rotated // 0' "$MANIFEST")"
  printf '%s' "${r:-0}"
}

# sec::manifest_set_rotated <name> <epoch> — stamp the entry.
sec::manifest_set_rotated() {
  sec::manifest_check
  name="$1" e="$2" yq -i '
    (.secrets[] | select(.name == strenv(name))) .rotated = (strenv(e) | to_number)
  ' "$MANIFEST"
}

# sec::gen_get <slot> <name> — epoch the slot last collected <name> (0 if never).
sec::gen_get() {
  [[ -f "$GENERATIONS" ]] || {
    printf '0'
    return 0
  }
  local g
  g="$(slot="$1" name="$2" yq -r \
    '.[strenv(slot)][strenv(name)] // 0' "$GENERATIONS")"
  printf '%s' "${g:-0}"
}

# sec::gen_set <slot> <name> <epoch>
sec::gen_set() {
  [[ -f "$GENERATIONS" ]] || {
    mkdir -p "${GENERATIONS:h}"
    print -r -- '{}' >"$GENERATIONS"
  }
  slot="$1" name="$2" e="$3" yq -i \
    '.[strenv(slot)][strenv(name)] = (strenv(e) | to_number)' "$GENERATIONS"
}

# sec::gen_del <slot> <name> — forget a removed secret's stamp (no-op if absent).
sec::gen_del() {
  [[ -f "$GENERATIONS" ]] || return 0
  slot="$1" name="$2" yq -i \
    'del(.[strenv(slot)][strenv(name)])' "$GENERATIONS"
}

# ---------------------------------------------------------------------------
# Profiles. The single shell-side list — keep in sync with
# home/.chezmoitemplates/profile-traits.tmpl (the template-side fail-closed
# authority; a bare zsh lib cannot include it).
# ---------------------------------------------------------------------------
SEC_PROFILES=(personal work dev-shell server)
sec::valid_profile() { (( ${SEC_PROFILES[(Ie)$1]} )); }

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
# Committed-artifact readers. Everything below reads ONLY committed files
# (fragment templates, blob dirs), so it works for foreign slots the local
# operator map knows nothing about — the basis of `remove`'s cross-slot scrub.
# ---------------------------------------------------------------------------

# sec::fragment_slots — every slot with a committed fragment template.
sec::fragment_slots() {
  local f base
  for f in "$FRAGMENT_DIR"/private_slot-*.sh.tmpl(N); do
    base="${${f:t}%.sh.tmpl}"
    printf '%s\n' "${base#private_}"
  done
}

# sec::slot_kind_from_fragment <slot> — headless|human|"" from the committed
# template's header comment (content-derived, so it needs no operator map and
# survives an empty secret set).
sec::slot_kind_from_fragment() {
  local frag content
  frag="$(sec::fragment_path "$1")"
  [[ -r "$frag" ]] || {
    printf ''
    return 0
  }
  content="$(<"$frag")"
  if [[ "$content" == *"headless slot"* ]]; then
    printf 'headless'
  elif [[ "$content" == *"human slot"* ]]; then
    printf 'human'
  else
    printf ''
  fi
}

# sec::fragment_references <slot> <name> — 0 iff the committed template still
# carries <name> (a sops blob path or an op:// item segment).
sec::fragment_references() {
  local frag content
  frag="$(sec::fragment_path "$1")"
  [[ -r "$frag" ]] || return 1
  content="$(<"$frag")"
  [[ "$content" == *"\"$2.sops.sh\""* || "$content" == *"/$2/"* ]]
}

# sec::human_slot_pairs <slot> — NAME=op://ref pairs parsed back out of a human
# fragment template, one per line (the inverse of sec::write_human_fragment).
sec::human_slot_pairs() {
  local frag line
  frag="$(sec::fragment_path "$1")"
  [[ -r "$frag" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ '^export ([A-Z][A-Z0-9_]*)=.*"(op://[^"]+)"' ]]; then
      printf '%s=%s\n' "${match[1]}" "${match[2]}"
    fi
  done <"$frag"
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

# sec::known_slots — every slot in the local operator map, one per line.
sec::known_slots() {
  [[ -f "$OPERATOR_MAP" ]] || return 0
  yq -r 'keys | .[]' "$OPERATOR_MAP" 2>/dev/null || true
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
  # Capture, then take the first line — `| head -n1` would SIGPIPE yq on a
  # second match (legacy + dir-wide rule both present) and, under the callers'
  # `set -eu -o pipefail`, kill the whole run from inside an assignment.
  local -a _ages
  _ages=("${(@f)$(rn="secrets/${1}/.*\\.sops\\.sh\$" ro="secrets/${1}\\.sops\\.sh\$" yq -r \
    '(.creation_rules // [])[] | select(.path_regex == strenv(rn) or .path_regex == strenv(ro)) | .age' \
    "$SOPS_YAML" 2>/dev/null)}")
  printf '%s' "${_ages[1]:-}"
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

# sec::scrub_slot_name <slot> <name> — drop <name> from a slot's COMMITTED
# artifacts: delete the sops blob and rewrite the fragment without it
# (headless), or rewrite the fragment without its op:// pair (human). Works on
# foreign slots too — removal needs no secret values, and the slot's kind is
# read from the committed template, not the operator map. Returns 0 iff
# something changed. Does NOT commit and does NOT touch 1Password (callers
# own both).
sec::scrub_slot_name() {
  local slot="$1" name="$2" kind changed=0
  kind="$(sec::slot_kind_from_fragment "$slot")"
  [[ -n "$kind" ]] || return 1
  if [[ "$kind" == headless ]]; then
    local blob
    blob="$(sec::blob_path "$slot" "$name")"
    if [[ -f "$blob" ]]; then
      rm -f "$blob"
      changed=1
    fi
    # The fragment may still list the name even when the blob is already gone
    # (a half-done manual removal); heal that too.
    sec::fragment_references "$slot" "$name" && changed=1
    if ((changed)); then
      local -a names
      names=("${(@f)$(sec::headless_slot_names "$slot")}")
      names=(${names:#})
      sec::write_headless_fragment "$slot" "${names[@]}"
    fi
  else
    local -a pairs keep
    pairs=("${(@f)$(sec::human_slot_pairs "$slot")}")
    pairs=(${pairs:#})
    keep=(${pairs:#$name=*})
    if ((${#keep} != ${#pairs})); then
      sec::write_human_fragment "$slot" "${keep[@]}"
      changed=1
    fi
  fi
  ((changed)) && sec::gen_del "$slot" "$name"
  ((changed))
}

# sec::shell_reload_hint — say how to get a just-rendered fragment into the shell
# the operator is standing in. Rewriting ~/.config/zsh/secrets.d/<slot>.sh cannot
# change the environment of the shell that ran us (we are its child), and the
# fragment is sourced exactly once, at startup: .zshenv -> environment.sh ->
# secrets.sh. So that session keeps the old values until it re-sources — which
# surprises you precisely when you just added a secret in order to use it.
#
# Names the loader rather than saying "restart your shell": re-sourcing is
# idempotent (the fragment is plain `export NAME=value`) and keeps the session.
#
# Silent when the caller has already committed to reloading for us — the zsh
# front-end in functions.d/system-secrets.sh sets SYSTEM_SECRETS_SHELL_RELOAD
# before invoking the binary and re-sources on its own afterwards. Two
# contradictory messages would be worse than neither.
sec::shell_reload_hint() {
  if [[ -z "${SYSTEM_SECRETS_SHELL_RELOAD:-}" ]]; then
    log_info "run '. ~/.config/zsh/secrets.sh' to load it into this shell (new shells get it automatically)"
  fi
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

# sec::op_scrub_field <name> <slot> — best-effort deletion of one slot's field
# on the secret's 1Password item. Uses only the CACHED vault (never prompts —
# scrubbing runs from non-interactive paths); prints the manual command when
# it cannot act. Hygiene, never a gate: always returns 0.
sec::op_scrub_field() {
  local name="$1" hash="${2#slot-}" vault
  if ! sec::op_available; then
    log_info "op unavailable — clean up manually: op item edit '$name' '${hash}[delete]'"
    return 0
  fi
  vault="$(sec::op_vault_get)"
  if [[ -z "$vault" ]]; then
    log_info "no cached 1Password vault — clean up manually: op item edit '$name' '${hash}[delete]'"
    return 0
  fi
  if sec::op item edit "$name" "${hash}[delete]" --vault "$vault" >/dev/null 2>&1; then
    log_ok "deleted 1Password field $hash on item $name"
  else
    log_warn "could not delete 1Password field $hash on item $name — clean up manually"
  fi
  return 0
}

# sec::op_scrub_item <name> — best-effort archive of the whole item (full
# removal). Same cached-vault-only, never-a-gate contract as op_scrub_field.
sec::op_scrub_item() {
  local name="$1" vault
  if ! sec::op_available; then
    log_info "op unavailable — clean up manually: op item delete '$name' --archive"
    return 0
  fi
  vault="$(sec::op_vault_get)"
  if [[ -z "$vault" ]]; then
    log_info "no cached 1Password vault — clean up manually: op item delete '$name' --archive"
    return 0
  fi
  if sec::op item delete "$name" --archive --vault "$vault" >/dev/null 2>&1; then
    log_ok "archived 1Password item $name"
  else
    log_warn "could not archive 1Password item $name — clean up manually"
  fi
  return 0
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
    # Herestring, not a pipe: grep -q's early exit would SIGPIPE the printf
    # side and fail the pipeline under the callers' `set -o pipefail`.
    if grep -iEq -- "$pat" <<<"$haystack"; then
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
    local _now_h
    _now_h="$(date +%s)"
    for n in "${names[@]}"; do sec::gen_set "$slot" "$n" "$_now_h"; done
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
    local _now_p
    _now_p="$(date +%s)"
    for n in "${names[@]}"; do sec::gen_set "$slot" "$n" "$_now_p"; done
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
  sec::manifest_requires "$profile" "$name" ||
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
    sec::gen_set "$slot" "$name" "$(date +%s)"
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
    sec::gen_set "$slot" "$name" "$(date +%s)"
    log_ok "wrote ${#pairs[@]} 1Password reference(s) for slot $slot"
  fi
}

# sec::sync_can_collect — 0 iff interactive value collection is possible.
# The seam the tty gate lives behind (overridable in tests); the same
# stdin-is-a-terminal check system-update's preauthorize_sudo uses.
sec::sync_can_collect() { [[ -t 0 ]]; }

# sec::sync_slot <slot> <profile> — reconcile the slot's COMMITTED artifacts
# with the manifest, both directions: scrub names the profile no longer
# requires (no values needed), collect names it now requires or whose value
# predates the manifest's `rotated` stamp (interactive; skipped with a report
# when no terminal). Commits once. Sets SEC_SYNC_CHANGED=1 iff anything moved
# (callers refresh the rendered fragment on that signal). Idempotent.
sec::sync_slot() {
  local slot="$1" profile="$2" kind
  typeset -g SEC_SYNC_CHANGED=""
  kind="$(sec::map_get "$slot" kind)"
  [[ -n "$kind" ]] ||
    die "slot $slot is not in this machine's operator map (run system-onboard first)"
  sec::valid_profile "$profile" ||
    die "unknown profile '$profile' (valid: ${(j:, :)SEC_PROFILES})"

  if [[ "$kind" == headless && -f "$(sec::legacy_blob_path "$slot")" ]]; then
    log_info "slot $slot still uses a monolithic blob; re-collecting once to migrate"
    sec::rebuild_slot "$slot"
    local -a mpaths
    mpaths=("${(@f)$(sec::commit_paths_for_slot "$slot")}")
    sec::git_commit "feat(secrets): sync $slot" "${mpaths[@]}"
    SEC_SYNC_CHANGED=1
    return 0
  fi

  local -a required current stale missing outdated
  required=("${(@f)$(sec::manifest_names_for_profile "$profile")}")
  required=(${required:#})
  if [[ "$kind" == headless ]]; then
    current=("${(@f)$(sec::headless_slot_names "$slot")}")
  else
    local -a pairs
    pairs=("${(@f)$(sec::human_slot_pairs "$slot")}")
    pairs=(${pairs:#})
    current=("${(@)pairs%%=*}")
  fi
  current=(${current:#})

  local n rot gen
  for n in "${current[@]}"; do
    (( ${required[(Ie)$n]} )) || stale+=("$n")
  done
  for n in "${required[@]}"; do
    if (( ! ${current[(Ie)$n]} )); then
      missing+=("$n")
    else
      # Rotation broadcast: collected before the last `rotate NAME` → re-collect.
      rot="$(sec::manifest_rotated "$n")"
      ((rot)) || continue
      gen="$(sec::gen_get "$slot" "$n")"
      ((gen >= rot)) || outdated+=("$n")
    fi
  done

  if ((${#stale} == 0 && ${#missing} == 0 && ${#outdated} == 0)); then
    log_ok "slot $slot already in sync with profile '$profile'"
    return 0
  fi

  local changed=0
  for n in "${stale[@]}"; do
    if sec::scrub_slot_name "$slot" "$n"; then
      changed=1
      [[ "$kind" == human ]] && sec::op_scrub_field "$n" "$slot"
    fi
  done
  ((${#stale})) && log_ok "scrubbed stale: ${(j:, :)stale}"

  local -a collect
  collect=("${missing[@]}" "${outdated[@]}")
  collect=(${collect:#})
  if ((${#collect})); then
    if sec::sync_can_collect; then
      ((${#outdated})) && log_info "rotated upstream, re-collecting: ${(j:, :)outdated}"
      for n in "${collect[@]}"; do
        sec::materialize_secret "$slot" "$n"
        changed=1
      done
    else
      log_warn "profile '$profile' needs values for: ${(j:, :)collect}"
      log_warn "run 'system-secrets sync' in a terminal to collect them"
    fi
  fi

  if ((changed)); then
    local -a paths
    paths=("${(@f)$(sec::commit_paths_for_slot "$slot")}")
    sec::git_commit "feat(secrets): sync $slot" "${paths[@]}"
    SEC_SYNC_CHANGED=1
  fi
  return 0
}

# sec::remove_secret <name> <profile> <all(0/1)> <yes(0/1)> — orchestrate
# `system-secrets remove`. Full removal (all=1, the no-flag default) scrubs
# EVERY committed slot artifact — removal needs no values, so one machine
# converges the whole repo. Profile-scoped removal scrubs only slots the
# local operator map assigns to that profile and names the foreign slots
# still referencing the secret (their machines converge via sync). Commits
# once; sets SEC_REMOVE_TOUCHED to the scrubbed slots (callers refresh their
# own rendered fragment from it).
sec::remove_secret() {
  local name="$1" profile="$2" all="$3" yes="$4"
  typeset -ga SEC_REMOVE_TOUCHED=()
  sec::manifest_has "$name" || die "'$name' is not in the manifest"

  if ((!all)); then
    sec::valid_profile "$profile" ||
      die "unknown profile '$profile' (valid: ${(j:, :)SEC_PROFILES})"
    local -a profs remaining
    profs=("${(@f)$(sec::manifest_profiles_for "$name")}")
    profs=(${profs:#})
    if (( ! ${profs[(Ie)$profile]} )); then
      log_warn "'$name' is not required for profile '$profile'; scrubbing any stale artifacts anyway"
    else
      remaining=(${profs:#$profile})
      if ((${#remaining} == 0)); then
        log_info "'$profile' is the last profile requiring '$name'"
        if ((yes)) || prompt::confirm "Remove '$name' from the manifest entirely?"; then
          all=1
        else
          log_info "aborted"
          return 0
        fi
      fi
    fi
  fi

  local -a touched foreign paths
  local s
  if ((all)); then
    for s in "${(@f)$(sec::fragment_slots)}"; do
      [[ -n "$s" ]] || continue
      if sec::scrub_slot_name "$s" "$name"; then touched+=("$s"); fi
    done
    sec::manifest_remove "$name"
    sec::op_scrub_item "$name"
  else
    for s in "${(@f)$(sec::known_slots)}"; do
      [[ -n "$s" ]] || continue
      [[ "$(sec::map_get "$s" profile)" == "$profile" ]] || continue
      if sec::scrub_slot_name "$s" "$name"; then
        touched+=("$s")
        [[ "$(sec::slot_kind_from_fragment "$s")" == human ]] &&
          sec::op_scrub_field "$name" "$s"
      fi
    done
    sec::manifest_remove_profile "$name" "$profile" || log_info "manifest already lacked '$profile' for '$name'"
    for s in "${(@f)$(sec::fragment_slots)}"; do
      [[ -n "$s" ]] || continue
      (( ${touched[(Ie)$s]} )) && continue
      [[ -n "$(sec::map_get "$s" kind)" ]] && continue
      if sec::fragment_references "$s" "$name"; then foreign+=("$s"); fi
    done
  fi

  paths=("$MANIFEST" "$GENERATIONS")
  for s in "${touched[@]}"; do
    paths+=("$(sec::fragment_path "$s")" "$(sec::blob_dir "$s")")
  done
  local msg
  if ((all)); then
    msg="feat(secrets): remove $name"
  else
    msg="feat(secrets): remove $name from $profile"
  fi
  sec::git_commit "$msg" "${paths[@]}"

  ((${#touched})) && log_ok "scrubbed: ${(j:, :)touched}"
  if ((${#foreign})); then
    log_info "slots outside this machine's operator map still reference '$name': ${(j:, :)foreign}" >&2
    log_info "machines of profile '$profile' among them drop it on their next 'system-secrets sync'" >&2
  fi
  SEC_REMOVE_TOUCHED=("${touched[@]}")
  return 0
}

# sec::commit_paths_for_slot <slot> — the committed paths a slot touches.
sec::commit_paths_for_slot() {
  local slot="$1"
  printf '%s\n' \
    "$(sec::fragment_path "$slot")" \
    "$SOPS_YAML" \
    "$MANIFEST" \
    "$GENERATIONS"
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
