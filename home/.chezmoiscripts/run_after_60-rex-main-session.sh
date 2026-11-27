#!/bin/sh
# Name Rex's default session "Main".
#
# Rex names the session it creates at first launch itself, adjective-noun
# (wandering-glade), and shows the current session's label in the tab bar as
# soon as there is a second session — which the Jobs session makes the normal
# case. This step, run on every apply, renames the OLDEST session whose label
# looks generated to "Main" when no session has that name yet. New sessions
# get a readable name where they are made (session_new_named in init.lua).
#
# Rules it keeps:
#   * NEVER START A SERVER, and never fail the apply: no rex, no jq, no
#     server, or an unreadable listing is a silent no-op.
#   * Only a label of the shape Rex generates (two lowercase words, one
#     hyphen) is a candidate, and never one that is a name or an id in the
#     Quick Launch config — a workspace called my-project is the owner's name.
#   * "Oldest" is read from the session ids, not from the order of the
#     listing: an id is a UUIDv7 (session:01a21e20-35a5-7be6-…), whose leading
#     48 bits are the creation time, so the ids sort in creation order as
#     text. Should any id have another shape, the listing order is kept.
#   * A session called Main in any case (main, MAIN) is the Main session.

# The Mac app keeps the CLI inside its server bundle and only puts it on PATH
# in the panes it starts, so an apply from any other shell needs the path.
rex="${MUX_REX_BIN:-}"
if [ -z "$rex" ]; then
  rex="$(command -v rex 2>/dev/null || true)"
fi
if [ -z "$rex" ]; then
  app="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  [ -x "$app" ] && rex="$app"
fi
[ -n "$rex" ] && [ -x "$rex" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

listing="$("$rex" --autostart=false ls --json 2>/dev/null)" || exit 0
[ -n "$listing" ] || exit 0

# Tab-separated "id<TAB>label" lines, oldest session first.
sessions="$(printf '%s' "$listing" | jq -r '
  def uuid7: type == "string" and test("^session:[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");
  [.sessions[]?]
  | if all(.[]; .session_id | uuid7) then sort_by(.session_id) else . end
  | .[] | [.session_id, .label] | @tsv' 2>/dev/null)" || exit 0
[ -n "$sessions" ] || exit 0

if printf '%s\n' "$sessions" | cut -f2 | grep -qix 'main'; then
  exit 0
fi

# Every name the Quick Launch config gives a workspace, tab or pane, one per
# line: the value of each `name:` and of each `id:` (a workspace with no name
# is called by its id). Read with sed rather than a YAML parser so the apply
# needs nothing installed; the key may open a list item ("- name: x"), and
# the value may be quoted or followed by a comment. Reading too many names is
# the safe direction: a label found here is simply never renamed.
ql_dir="$HOME/.config/mux/quick-launch"
ql_names=""
if [ -d "$ql_dir" ]; then
  ql_names="$(find "$ql_dir" -name '*.yaml' -type f -exec sed -n -E \
    's/^[[:space:]]*(-[[:space:]]+)?(name|id):[[:space:]]*//p' {} + 2>/dev/null \
    | sed -E -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//' \
      -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'\$/\1/")"
fi

printf '%s\n' "$sessions" | while IFS="$(printf '\t')" read -r id label; do
  printf '%s\n' "$label" | grep -Eqx '[a-z]+-[a-z]+' || continue
  if [ -n "$ql_names" ] && printf '%s\n' "$ql_names" | grep -Fqx -- "$label"; then
    continue
  fi
  "$rex" --autostart=false session rename "$id" Main >/dev/null 2>&1 || :
  break
done

exit 0
