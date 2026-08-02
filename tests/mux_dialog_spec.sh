# Tests for mux/dialog.zsh — the tmux search/rename popup chrome.
#
# C1 consolidation: mux_dialog::_fg/_bg used zsh slices ${1[2,3]} that REQUIRE
# a leading '#' and silently mis-parse a bare hex. They now route through the
# canonical theme::sgr_fg/theme::sgr_bg (which strip an optional '#'), so
# mux_dialog::init builds the correct escape from both hex forms.
Describe 'mux/dialog.zsh — init colors (C1)'
  Include home/dot_local/lib/mux/dialog.zsh

  setup() {
    MD_TMP=$(mktemp -d)
    export THEME_PALETTE_JSON="$MD_TMP/theme.json"
  }
  cleanup() { rm -rf "$MD_TMP"; unset THEME_PALETTE_JSON XDG_CONFIG_HOME XDG_CACHE_HOME; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # accent = .extended.dialog.search_accent = #89b4fa -> 137;180;250
  accent_fg() { printf '\033[38;2;137;180;250m'; }
  accent_bg() { printf '\033[48;2;137;180;250m'; }

  It 'builds the accent escapes from a #-prefixed palette (unchanged)'
    cat > "$THEME_PALETTE_JSON" <<'EOS'
{"extended":{"tab":{"bg":"#282c41"},"dialog":{"search_accent":"#89b4fa"}},
 "roles":{"ui":{"bg":"#1e1e2e","dialog_bg":"#313244","border_inactive":"#585b70"},
          "action":{"attention":"#f9e2af"}},
 "palette":{"white":"#ffffff"}}
EOS
    check() { mux_dialog::init && print -rn -- "$MD_ACCENT_FG$MD_ACCENT_BG"; }
    When call check
    The output should equal "$(accent_fg)$(accent_bg)"
  End

  # Regression (latent bug fixed): a bare (no-#) hex used to mis-parse through
  # the ${1[2,3]} slice; the canonical strips the optional '#', so this now
  # yields the identical escape.
  It 'builds the same accent escapes from a bare (no-#) palette'
    cat > "$THEME_PALETTE_JSON" <<'EOS'
{"extended":{"tab":{"bg":"282c41"},"dialog":{"search_accent":"89b4fa"}},
 "roles":{"ui":{"bg":"1e1e2e","dialog_bg":"313244","border_inactive":"585b70"},
          "action":{"attention":"f9e2af"}},
 "palette":{"white":"ffffff"}}
EOS
    check() { mux_dialog::init && print -rn -- "$MD_ACCENT_FG$MD_ACCENT_BG"; }
    When call check
    The output should equal "$(accent_fg)$(accent_bg)"
  End

  # C2 split-palette fix: mux_dialog::init resolves via theme::json_path, so the
  # override ($THEME_PALETTE_JSON — the tinted cache copy .zshrc exports under
  # SSH) wins over the canonical config tier. The dialog now reads the SAME file
  # the status bar does; no more two palettes on one screen. Retires the old
  # THEME_JSON seam.
  It 'honours $THEME_PALETTE_JSON over a decoy canonical palette (split-palette fix)'
    export XDG_CONFIG_HOME="$MD_TMP/config"
    mkdir -p "$XDG_CONFIG_HOME/theme"
    # decoy canonical (config tier): a RED accent that must NOT be used
    cat > "$XDG_CONFIG_HOME/theme/chezmoi-system.json" <<'EOS'
{"extended":{"tab":{"bg":"#000000"},"dialog":{"search_accent":"#ff0000"}},
 "roles":{"ui":{"bg":"#000000","dialog_bg":"#000000","border_inactive":"#000000"},
          "action":{"attention":"#000000"}},
 "palette":{"white":"#000000"}}
EOS
    # the override the shell exports (setup points $THEME_PALETTE_JSON here)
    cat > "$THEME_PALETTE_JSON" <<'EOS'
{"extended":{"tab":{"bg":"#282c41"},"dialog":{"search_accent":"#89b4fa"}},
 "roles":{"ui":{"bg":"#1e1e2e","dialog_bg":"#313244","border_inactive":"#585b70"},
          "action":{"attention":"#f9e2af"}},
 "palette":{"white":"#ffffff"}}
EOS
    check() { mux_dialog::init && print -rn -- "$MD_ACCENT_FG"; }
    When call check
    The output should equal "$(accent_fg)"
  End
End
