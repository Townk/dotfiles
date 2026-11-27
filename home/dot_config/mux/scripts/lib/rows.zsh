#!/usr/bin/env zsh
# rows.zsh — quick-launch targets as plain picker rows.
#
# quick-launch-pick assembles its rows INSIDE an fzf pipeline: ANSI colour,
# nerd-font glyphs, hidden tail fields, pick-common's wire format. None of
# that survives outside fzf. This is the same list for a picker that draws
# itself — Rex's native palette (`rex.ui.pick`) — as five tab-separated
# fields per line, already in display order:
#
#     <id> \t <title> \t <subtitle> \t <icon> \t <detail>
#
# The ORDERING and FILTERING rules are the picker's, restated — they are the
# behaviour, and the two surfaces must not disagree about them:
#
#   workspaces  the session we are in is omitted; live sessions first, then
#               ad-hoc ones (live, but not defined in any targets file), then
#               the defined-but-not-running rest; on top of that order, the
#               recency cache floats recently picked ids to the front.
#               detail = "detached" / "other window" (+ "ad-hoc").
#   panes       the active tab's panes, then the active workspace's, then the
#               global ones, deduped by id — which is also what makes an
#               `optional` pane appear only inside its parent.
#   tabs        the defined tabs, in file order.
#
# <icon> is one of Rex's fixed icon names, chosen from the action type. The
# target's own `icon` glyph is not used: the palette cannot draw it.
#
# Needs QL_JSON (ql_load) and the mux shim (command.zsh sources it).

# ql_usage_file <kind> — the recency cache quick-launch-pick keeps for that
# kind, or nothing: only workspaces have one. One id per line, most recent
# first — pick-common's format, shared so both pickers feed the same history.
ql_usage_file() {
  [[ "$1" == workspace ]] || return 1
  print -r -- "${XDG_CACHE_HOME:-$HOME/.cache}/quick-launch/usage-workspace"
}

# ql_record_usage <kind> <id> — move <id> to the front of the recency cache
# (deduped, capped at 50, as pick::record does). A no-op for kinds without one.
ql_record_usage() {
  local f id="$2"
  f="$(ql_usage_file "$1")" || return 0
  [[ -n "$id" ]] || return 0
  local -a old=() out=("$id")
  [[ -s "$f" ]] && old=("${(@f)$(<"$f")}")
  local l
  for l in "${old[@]}"; do
    [[ -n "$l" && "$l" != "$id" ]] && out+=("$l")
  done
  mkdir -p -- "${f:h}" 2>/dev/null || return 0
  print -rl -- "${out[@]:0:50}" >| "$f"
}

# ql_rows <pane|tab|workspace>
ql_rows() {
  local kind="$1" key
  case "$kind" in
    pane) key=panes ;;
    tab) key=tabs ;;
    workspace) key=workspaces ;;
    *) echo "quick-launch: unknown kind '$kind' (want pane|tab|workspace)" >&2; return 2 ;;
  esac

  local active_ws active_tab live_json='[]' windowed_json='[]' usage_json='[]'
  active_ws="$(mux::current_session 2>/dev/null || true)"
  active_tab="$(mux::current_tab_name 2>/dev/null || true)"
  if [[ "$kind" == workspace ]]; then
    live_json="$({ mux::list_sessions 2>/dev/null | sed '/^$/d' | jq -R . | jq -s -c .; } 2>/dev/null || true)"
    [[ -n "$live_json" ]] || live_json='[]'
    windowed_json="$({ mux::attached_sessions 2>/dev/null | sed '/^$/d' | jq -R . | jq -s -c .; } 2>/dev/null || true)"
    [[ -n "$windowed_json" ]] || windowed_json='[]'
    local uf
    uf="$(ql_usage_file workspace)"
    [[ -s "$uf" ]] && usage_json="$(sed '/^$/d' "$uf" | jq -R . | jq -s -c .)"
    [[ -n "$usage_json" ]] || usage_json='[]'
  fi

  jq -r --arg k "$key" --arg ws "$active_ws" --arg tab "$active_tab" \
    --argjson live "$live_json" --argjson windowed "$windowed_json" \
    --argjson usage "$usage_json" '
    def icon($t):
      if   $t == "Shell"  then "terminal"
      elif $t == "Edit"   then "code"
      elif $t == "Remote" then "server"
      elif $t == "Run"    then "gear"
      else "folder" end;
    def session_title:
      split("-")
      | map(if length == 0 then . else (.[0:1] | ascii_upcase) + .[1:] end)
      | join(" ");
    def clean: tostring | gsub("[\t\n\r]"; " ");
    def sname: .name // .id;
    def is_live: . as $w | ($live | index($w | sname)) != null;
    def in_window: . as $w | ($windowed | index($w | sname)) != null;
    def detail:
      [ if (.ad_hoc // false) then "ad-hoc" else empty end,
        if ((.ad_hoc // false) or is_live)
          then (if in_window then "other window" else "detached" end)
          else empty end ]
      | join(", ");
    # What a row says under its title: where it lands, or what it runs.
    def subtitle:
      (.action // {}) as $a
      | if ($a.type // "") == "Remote" then "ssh " + (($a.args // []) | join(" "))
        elif ($a.cwd // "") != "" then $a.cwd
        elif ($a.type // "") == "Run" then (($a.args // []) | join(" && "))
        elif (.tabs // [] | length) > 0 then ((.tabs | length | tostring) + " tabs")
        else "" end;
    # A Run line can be a whole shell program; the palette shows one quiet
    # line under the title, so keep the start of it.
    def short: if length > 72 then .[0:71] + "…" else . end;
    def row($label; $detail):
      [ .id, $label, (subtitle | short), icon(.action.type // ""), $detail ] | map(clean) | join("\t");
    def collect_panes:
      ( (.workspaces // []) | map(select(.id == $ws or .name == $ws)) | (.[0] // null) ) as $aws
      | ( ( (.tabs // []) | map(select(.name == $tab or .id == $tab)) | .[0] )
          // ( ($aws.tabs // []) | map(select(.name == $tab or .id == $tab)) | .[0] )
        ) as $atab
      | [ ($atab.panes // [])[], ($aws.panes // [])[], (.panes // [])[] ]
      | reduce .[] as $p ([]; if any(.[]; .id == $p.id) then . else . + [$p] end);
    # Stable recency float: ids in the usage list first, in its order.
    def by_recency:
      . as $rows
      | ( [ $usage[] as $u | $rows[] | select(.id == $u) ] ) as $recent
      | $recent + [ $rows[] | select(.id as $i | ($usage | index($i)) == null) ];

    if $k == "workspaces" then
      ( [ .workspaces[]? | select(sname != $ws) ] ) as $wss
      | ( $wss | map(sname) ) as $defined
      | ( [ $live[] | select(. != $ws) | select(IN($defined[]) | not)
            | { id: ., name: ., ad_hoc: true } ] ) as $adhoc
      | ( ( $wss | map(select(is_live)) ) + $adhoc + ( $wss | map(select(is_live | not)) ) )
      | by_recency
      | .[]
      | row( (.action.label // (sname | session_title)); detail )
    elif $k == "panes" then
      collect_panes | .[] | row( (.action.label // .name // .id); "" )
    else
      .[$k][]? | row( (.action.label // .name // .id); "" )
    end
  ' <<<"$QL_JSON"
}
