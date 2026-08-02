# Tests for theme-common.zsh — semantic tokens + theme helpers.
Describe 'theme-common.zsh'
  Include home/dot_local/lib/theme-common.zsh

  It 'maps THEME_SEPARATOR to the surface0 color'
    When call test "$THEME_SEPARATOR" = "$C_SURFACE0"
    The status should be success
  End

  It 'maps THEME_ACCENT to mauve'
    When call test "$THEME_ACCENT" = "$C_MAUVE"
    The status should be success
  End

  It 'theme::rule emits a sized bar at an explicit width'
    When call theme::rule 10
    The output should equal "━━━━━━"
  End

  # Regression: theme::rule is called by zellij-modal, which runs under
  # `set -euo pipefail`. A bare ${(l:cols::━:)} fill aborts under nounset
  # ("parameter not set"), silently killing every modal dialog before it
  # spawns its target. Run in a real nounset shell to guard that path.
  It 'theme::rule is nounset-safe (set -u)'
    When run zsh -uc 'source home/dot_local/lib/theme-common.zsh; theme::rule 10'
    The output should equal "━━━━━━"
    The status should be success
  End

  # ── hex → SGR (C1 canonical) ───────────────────────────────────────────────
  # theme::sgr_fg / theme::sgr_bg are the single hex→24-bit-SGR pair; the C1
  # consolidation folded the fzf-tab-rich xdigit guard in and routed six copies
  # (pick / backup-tm / mux_dialog / mux-whichkey / fzf-tab-rich) here.
  Describe 'theme::sgr_fg / theme::sgr_bg'
    It 'builds the exact truecolor set-foreground escape'
      When call theme::sgr_fg '#e5bf7b'
      The output should equal "$(printf '\033[38;2;229;191;123m')"
    End

    It 'builds the exact truecolor set-background escape'
      When call theme::sgr_bg '#e5bf7b'
      The output should equal "$(printf '\033[48;2;229;191;123m')"
    End

    # A leading '#' is optional: the six former copies split on it two
    # different ways (some sliced ${1[2,3]} and REQUIRED the '#'); the
    # canonical strips it so both forms land on the identical escape. This
    # is the "latent bug fixed" for the mux_dialog / mux-whichkey family.
    It 'accepts a bare (no-#) hex and yields the same escape as the #-form'
      hashed()  { theme::sgr_fg '#e5bf7b'; }
      bare()    { theme::sgr_fg 'e5bf7b'; }
      When call bare
      The output should equal "$(hashed)"
    End

    It 'accepts a bare hex for the background escape too'
      hashed()  { theme::sgr_bg '#e5bf7b'; }
      bare()    { theme::sgr_bg 'e5bf7b'; }
      When call bare
      The output should equal "$(hashed)"
    End

    # The folded-in guard: an empty / renamed palette token must emit NOTHING,
    # not \e[38;2;0;0;0m (black-on-black in a dialog footer).
    It 'emits nothing for empty input (guard, not black-on-black)'
      When call theme::sgr_fg ''
      The output should equal ''
    End

    It 'emits nothing for the background on empty input'
      When call theme::sgr_bg ''
      The output should equal ''
    End

    It 'emits nothing for a non-hex token'
      When call theme::sgr_fg 'zzz'
      The output should equal ''
    End

    It 'emits nothing for a too-short hex'
      When call theme::sgr_fg '#abc'
      The output should equal ''
    End
  End

  # ── hex → "R G B" decimal triple (C1: component consumers) ──────────────────
  Describe 'theme::hex_rgb'
    It 'prints the space-separated decimal triple'
      When call theme::hex_rgb '#e5bf7b'
      The output should equal '229 191 123'
    End

    It 'accepts a bare (no-#) hex'
      When call theme::hex_rgb 'e5bf7b'
      The output should equal '229 191 123'
    End

    It 'emits nothing for invalid / empty input (same guard)'
      When call theme::hex_rgb ''
      The output should equal ''
    End
  End

  # ── single palette JSON path (C2 canonical) ─────────────────────────────────
  # theme::json_path is THE resolver every reader shares, so the status bar and
  # the dialogs can never render different palettes on one screen (the split-
  # palette-under-SSH bug). ONE order: $THEME_PALETTE_JSON (the sole override
  # .zshrc exports) -> the effective cache copy if readable -> the canonical
  # config copy. The retired WIDGETS_THEME_JSON / THEME_JSON seams collapse here.
  Describe 'theme::json_path'
    setup() {
      TJ_TMP=$(mktemp -d)
      export HOME="$TJ_TMP/home"
      export XDG_CACHE_HOME="$TJ_TMP/cache" XDG_CONFIG_HOME="$TJ_TMP/config"
      # The ambient login shell exports THEME_PALETTE_JSON (see .zshrc); drop it
      # so the fallback tiers are exercised hermetically.
      unset THEME_PALETTE_JSON
      mkdir -p "$XDG_CACHE_HOME/theme" "$XDG_CONFIG_HOME/theme" "$HOME/.cache" "$HOME/.config"
    }
    cleanup() { rm -rf "$TJ_TMP"; unset TJ_TMP XDG_CACHE_HOME XDG_CONFIG_HOME THEME_PALETTE_JSON; }
    BeforeEach 'setup'
    AfterEach 'cleanup'

    It 'returns $THEME_PALETTE_JSON verbatim when set (the sole override)'
      export THEME_PALETTE_JSON="$TJ_TMP/explicit.json"
      : >"$XDG_CACHE_HOME/theme/chezmoi-system.json"   # present, but the override wins
      When call theme::json_path
      The output should equal "$TJ_TMP/explicit.json"
    End

    It 'falls back to the effective cache copy when unset and the cache is readable'
      : >"$XDG_CACHE_HOME/theme/chezmoi-system.json"
      When call theme::json_path
      The output should equal "$XDG_CACHE_HOME/theme/chezmoi-system.json"
    End

    It 'falls back to the canonical config copy when neither override nor cache is present'
      When call theme::json_path
      The output should equal "$XDG_CONFIG_HOME/theme/chezmoi-system.json"
    End

    It 'honours the $HOME defaults when XDG_* are unset'
      unset XDG_CACHE_HOME XDG_CONFIG_HOME
      When call theme::json_path
      The output should equal "$HOME/.config/theme/chezmoi-system.json"
    End
  End

  # ── themed gum env (Wave 2 consolidation) ───────────────────────────────────
  # theme::gum_confirm_env exports the canonical GUM_CONFIRM_* palette so every
  # zsh caller (dot_zshrc gpg-fwd confirm, backup-tm halt) themes `gum confirm`
  # from ONE place; pbpaste mirrors the SAME field->palette map through its POSIX
  # jq detour. theme::gum_style_env is the sibling for `gum style` (pick-clipboard
  # restore-failure box). Values below are HAND-DERIVED from a known palette
  # (sentinels set per-example, independent of theme.yaml). Raw hex is fine in a
  # spec — lint-theme.sh only scans home/.
  Describe 'theme::gum_confirm_env'
    known_palette() {
      C_HEX_DIALOG_WARNING='#e5bf7b'; C_HEX_DIALOG_DANGER='#ff5555'
      C_HEX_CRUST='#11111b'; C_HEX_SUBTEXT='#a6adc8'; C_HEX_SURFACE0='#313244'
    }

    warning_env() { known_palette; theme::gum_confirm_env; }
    It 'exports the warning confirm palette by default'
      When call warning_env
      The variable GUM_CONFIRM_PROMPT_FOREGROUND should equal '#e5bf7b'
      The variable GUM_CONFIRM_SELECTED_BACKGROUND should equal '#e5bf7b'
      The variable GUM_CONFIRM_SELECTED_FOREGROUND should equal '#11111b'
      The variable GUM_CONFIRM_UNSELECTED_FOREGROUND should equal '#a6adc8'
      The variable GUM_CONFIRM_UNSELECTED_BACKGROUND should equal '#313244'
      The variable COLORTERM should equal 'truecolor'
    End

    warning_role_env() { known_palette; theme::gum_confirm_env --role warning; }
    It 'treats --role warning as the default'
      When call warning_role_env
      The variable GUM_CONFIRM_PROMPT_FOREGROUND should equal '#e5bf7b'
      The variable GUM_CONFIRM_SELECTED_BACKGROUND should equal '#e5bf7b'
    End

    danger_env() { known_palette; theme::gum_confirm_env --role danger; }
    It 'swaps ONLY the accent (prompt + selected bg) for --role danger'
      When call danger_env
      The variable GUM_CONFIRM_PROMPT_FOREGROUND should equal '#ff5555'
      The variable GUM_CONFIRM_SELECTED_BACKGROUND should equal '#ff5555'
      The variable GUM_CONFIRM_SELECTED_FOREGROUND should equal '#11111b'
      The variable GUM_CONFIRM_UNSELECTED_FOREGROUND should equal '#a6adc8'
      The variable GUM_CONFIRM_UNSELECTED_BACKGROUND should equal '#313244'
    End

    # The two-level fallback chain must survive a renamed/empty palette token,
    # exactly as dot_zshrc's former inline env prefix did.
    empty_env() {
      C_HEX_DIALOG_WARNING=''; C_HEX_YELLOW=''; C_HEX_CRUST=''; C_HEX_BASE=''
      C_HEX_SUBTEXT=''; C_HEX_SURFACE0=''
      theme::gum_confirm_env
    }
    It 'falls back to named colors when palette tokens are empty'
      When call empty_env
      The variable GUM_CONFIRM_PROMPT_FOREGROUND should equal 'yellow'
      The variable GUM_CONFIRM_SELECTED_BACKGROUND should equal 'yellow'
      The variable GUM_CONFIRM_SELECTED_FOREGROUND should equal 'black'
      The variable GUM_CONFIRM_UNSELECTED_FOREGROUND should equal 'white'
      The variable GUM_CONFIRM_UNSELECTED_BACKGROUND should equal 'black'
    End
  End

  Describe 'theme::gum_style_env'
    danger_style() { C_HEX_DIALOG_DANGER='#ff5555'; C_HEX_RED='#f38ba8'; theme::gum_style_env; }
    It 'exports the danger style palette by default'
      When call danger_style
      The variable GUM_STYLE_FOREGROUND should equal '#ff5555'
      The variable GUM_STYLE_BORDER_FOREGROUND should equal '#ff5555'
    End

    warning_style() { C_HEX_DIALOG_WARNING='#e5bf7b'; theme::gum_style_env --role warning; }
    It 'swaps the accent for --role warning'
      When call warning_style
      The variable GUM_STYLE_FOREGROUND should equal '#e5bf7b'
      The variable GUM_STYLE_BORDER_FOREGROUND should equal '#e5bf7b'
    End

    danger_fallback() { C_HEX_DIALOG_DANGER=''; C_HEX_RED=''; theme::gum_style_env; }
    It 'falls back to red when the danger token is empty'
      When call danger_fallback
      The variable GUM_STYLE_FOREGROUND should equal 'red'
      The variable GUM_STYLE_BORDER_FOREGROUND should equal 'red'
    End
  End
End
