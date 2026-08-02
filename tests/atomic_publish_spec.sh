# Tests for atomic-publication of the custom builds + theme generator.
#
# Every one of these guards the same class of bug: a builder/generator that
# DESTROYS (or truncates) the live artifact BEFORE its replacement is built and
# validated, so a failed build/render/copy leaves the machine with a broken (or
# missing) shell / colorscript / theme and no rollback.
#
# The heavy real steps (compiling zsh, cloning upstream repos, fetching the
# catppuccin engine) are NOT run: the atomicity LOGIC is tested with the
# install/validate/render steps stubbed, per the task.

# ─────────────────────────────────────────────────────────────────────────────
# build-zsh.sh — stage → validate → atomic swap with rollback
# ─────────────────────────────────────────────────────────────────────────────
Describe 'build-zsh.sh stage_and_swap (atomic install)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/custom-builds/zsh/build-zsh.sh"

  setup() {
    TMP="$(mktemp -d)"
    export ZSH_BUILD_PREFIX="$TMP/opt/zsh"
    export ZSH_BUILD_STAGE="$ZSH_BUILD_PREFIX.new"
    export ZSH_BUILD_BACKUP="$ZSH_BUILD_PREFIX.old"
    mkdir -p "$ZSH_BUILD_PREFIX/bin"
    echo LIVE >"$ZSH_BUILD_PREFIX/marker"
  }
  cleanup() {
    rm -rf "$TMP"
    unset TMP ZSH_BUILD_PREFIX ZSH_BUILD_STAGE ZSH_BUILD_BACKUP
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # Source the script (main-guarded, so no compile), stub the install/validate
  # seams per STUB_MODE, then drive stage_and_swap directly.
  swap() {
    STUB_MODE="$1" bash -c '
      source "$1"
      case "$STUB_MODE" in
        install-fail)
          install_stage()  { mkdir -p "$1/bin"; echo STAGED >"$1/marker"; return 1; }
          validate_stage() { return 0; }
          ;;
        validate-fail)
          install_stage()  { mkdir -p "$1/bin"; echo STAGED >"$1/marker"; return 0; }
          validate_stage() { return 1; }
          ;;
        success)
          install_stage()  { mkdir -p "$1/bin"; echo NEW >"$1/marker"; return 0; }
          validate_stage() { [ -f "$1/marker" ]; }
          ;;
        postswap-fail)
          install_stage()  { mkdir -p "$1/bin"; echo NEW >"$1/marker"; return 0; }
          # pass on the staging dir, fail on the in-place re-validation.
          validate_stage() { case "$1" in *.new) return 0;; *) return 1;; esac; }
          ;;
      esac
      stage_and_swap
    ' _ "$SCRIPT"
  }

  It 'preserves the live prefix when the staged install fails'
    When run swap install-fail
    The status should be failure
    The stderr should include 'left intact'
    The contents of file "$ZSH_BUILD_PREFIX/marker" should equal 'LIVE'
    The path "$ZSH_BUILD_STAGE" should not be exist
  End

  It 'preserves the live prefix when staging validation fails'
    When run swap validate-fail
    The status should be failure
    The stderr should include 'failed validation'
    The contents of file "$ZSH_BUILD_PREFIX/marker" should equal 'LIVE'
    The path "$ZSH_BUILD_STAGE" should not be exist
  End

  It 'atomically swaps in the new build and drops the backup on success'
    When run swap success
    The status should be success
    The contents of file "$ZSH_BUILD_PREFIX/marker" should equal 'NEW'
    The path "$ZSH_BUILD_BACKUP" should not be exist
    The path "$ZSH_BUILD_STAGE" should not be exist
  End

  It 'rolls back to the previous build when post-swap validation fails'
    When run swap postswap-fail
    The status should be failure
    The stderr should include 'rolled back'
    The contents of file "$ZSH_BUILD_PREFIX/marker" should equal 'LIVE'
    The path "$ZSH_BUILD_BACKUP" should not be exist
  End
End

# ─────────────────────────────────────────────────────────────────────────────
# build-colorscripts.sh — stage → self-test → atomic swap with rollback
# ─────────────────────────────────────────────────────────────────────────────
Describe 'build-colorscripts.sh stage_and_swap (atomic install)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/custom-builds/colorscripts/build-colorscripts.sh"

  setup() {
    TMP="$(mktemp -d)"
    export COLORSCRIPTS_PREFIX="$TMP/opt/colorscripts"
    export COLORSCRIPTS_STAGE="$COLORSCRIPTS_PREFIX.new"
    export COLORSCRIPTS_BACKUP="$COLORSCRIPTS_PREFIX.old"
    mkdir -p "$COLORSCRIPTS_PREFIX/bin"
    echo LIVE >"$COLORSCRIPTS_PREFIX/marker"
  }
  cleanup() {
    rm -rf "$TMP"
    unset TMP COLORSCRIPTS_PREFIX COLORSCRIPTS_STAGE COLORSCRIPTS_BACKUP
  }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  swap() {
    STUB_MODE="$1" bash -c '
      source "$1"
      case "$STUB_MODE" in
        install-fail)
          install_stage()  { mkdir -p "$1/bin"; echo STAGED >"$1/marker"; return 1; }
          validate_stage() { return 0; }
          ;;
        validate-fail)
          install_stage()  { mkdir -p "$1/bin"; echo STAGED >"$1/marker"; return 0; }
          validate_stage() { return 1; }
          ;;
        success)
          install_stage()  { mkdir -p "$1/bin"; echo NEW >"$1/marker"; return 0; }
          validate_stage() { [ -f "$1/marker" ]; }
          ;;
      esac
      stage_and_swap
    ' _ "$SCRIPT"
  }

  It 'preserves the live prefix when the staged install fails'
    When run swap install-fail
    The status should be failure
    The stderr should include 'left intact'
    The contents of file "$COLORSCRIPTS_PREFIX/marker" should equal 'LIVE'
    The path "$COLORSCRIPTS_STAGE" should not be exist
  End

  It 'preserves the live prefix when the staged self-test fails'
    When run swap validate-fail
    The status should be failure
    The stderr should include 'self-test'
    The contents of file "$COLORSCRIPTS_PREFIX/marker" should equal 'LIVE'
    The path "$COLORSCRIPTS_STAGE" should not be exist
  End

  It 'atomically swaps in the new install and drops the backup on success'
    When run swap success
    The status should be success
    The contents of file "$COLORSCRIPTS_PREFIX/marker" should equal 'NEW'
    The path "$COLORSCRIPTS_BACKUP" should not be exist
    The path "$COLORSCRIPTS_STAGE" should not be exist
  End
End

# ─────────────────────────────────────────────────────────────────────────────
# generate-theme.sh — render to temp then mv (never truncate the live file)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'generate-theme.sh render atomicity (#3b redirect-into-live)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/custom-builds/theme/generate-theme.sh"

  setup() {
    TMP="$(mktemp -d)"
    DEST="$TMP/home"
    BIN="$TMP/bin"
    COUNTER="$TMP/count"
    mkdir -p "$BIN" "$DEST/.config/theme"
    : >"$COUNTER"
    # The 3rd render (palette.lua -> .config/theme/chezmoi-system.lua) already
    # exists as a live artifact; assert it survives a render failure untouched.
    LIVE_OUT="$DEST/.config/theme/chezmoi-system.lua"
    echo 'LIVE-LUA' >"$LIVE_OUT"
    # Stub chezmoi: succeed for every render except the Nth (FAIL_ON), so we
    # can fail exactly ONE artifact after earlier ones already rendered.
    {
      echo '#!/bin/sh'
      echo 'c=$(cat "$COUNTER" 2>/dev/null || echo 0); c=$((c+1)); printf "%s" "$c" >"$COUNTER"'
      echo 'if [ "$c" = "$FAIL_ON" ]; then exit 1; fi'
      echo 'echo "RENDERED-$c"'
    } >"$BIN/chezmoi"
    chmod +x "$BIN/chezmoi"
  }
  cleanup() { rm -rf "$TMP"; unset TMP DEST BIN COUNTER LIVE_OUT; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_gen() {
    PATH="$BIN:$PATH" THEME_DEST="$DEST" COUNTER="$COUNTER" FAIL_ON=3 \
      bash "$SCRIPT"
  }

  It 'leaves the live artifact intact and exits non-zero when a render fails'
    When run run_gen
    The status should be failure
    The stderr should include 'render failed'
    # The failed artifact keeps its previous content (not truncated to empty).
    The contents of file "$LIVE_OUT" should equal 'LIVE-LUA'
    # Earlier artifacts rendered normally before the failure.
    The contents of file "$DEST/.config/theme/chezmoi-system.zsh" should equal 'RENDERED-1'
    The contents of file "$DEST/.config/theme/chezmoi-system.json" should equal 'RENDERED-2'
    The stdout should be present
  End
End

# ─────────────────────────────────────────────────────────────────────────────
# generate-theme.sh — nvim ctp engine copied into .new then swapped (B2)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'generate-theme.sh nvim ctp atomicity (B2 rm-before-copy)'
  SCRIPT="$SHELLSPEC_PROJECT_ROOT/custom-builds/theme/generate-theme.sh"

  setup() {
    TMP="$(mktemp -d)"
    DEST="$TMP/home"
    CACHE="$TMP/ctp-cache"
    CTP="$DEST/.config/nvim/lua/chezmoi_theme/ctp"
    mkdir -p "$CACHE/lua/catppuccin/groups/integrations"
    for g in editor syntax treesitter semantic_tokens lsp; do
      echo "-- $g" >"$CACHE/lua/catppuccin/groups/$g.lua"
    done
    # Every integration EXCEPT dap.lua — the 2nd item in the copy loop — so a
    # `cp` fails mid-loop (a renamed/removed upstream file), the exact B2 case.
    for i in blink_cmp dap_ui flash gitsigns illuminate lsp_trouble mason mini \
             navic noice render_markdown snacks treesitter_context which_key; do
      echo "-- $i" >"$CACHE/lua/catppuccin/groups/integrations/$i.lua"
    done
    echo 'LICENSE' >"$CACHE/LICENSE.md"
    # Pre-existing live engine dir that must survive the failed rebuild.
    mkdir -p "$CTP/groups"
    echo 'LIVE-ENGINE' >"$CTP/sentinel"
  }
  cleanup() { rm -rf "$TMP"; unset TMP DEST CACHE CTP; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_gen() {
    THEME_DEST="$DEST" THEME_CTP_CACHE="$CACHE" THEME_CTP_NO_FETCH=1 \
      bash "$SCRIPT"
  }

  It 'leaves the live nvim engine dir intact when a source file is missing'
    When run run_gen
    The status should be failure
    The stderr should be present
    # The live engine dir is untouched (was: rm -rf before the copy loop).
    The contents of file "$CTP/sentinel" should equal 'LIVE-ENGINE'
    The stdout should be present
  End
End

# ─────────────────────────────────────────────────────────────────────────────
# run_onchange_after_54 — generator failure is now FATAL
# ─────────────────────────────────────────────────────────────────────────────
Describe 'run_onchange_after_54 (generator failure propagation)'
  TPL="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_54-generate-theme.sh.tmpl"

  setup() {
    TMP="$(mktemp -d)"
    HOOK="$TMP/hook54.sh"
    command chezmoi execute-template <"$TPL" >"$HOOK" 2>/dev/null
  }
  cleanup() { rm -rf "$TMP"; unset TMP HOOK; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'exits non-zero when the generator fails'
    stub="$TMP/gen-fail"; printf '#!/bin/sh\nexit 3\n' >"$stub"; chmod +x "$stub"
    When run command env GENERATE_THEME_BIN="$stub" bash "$HOOK"
    The status should be failure
    The stdout should be present
  End

  It 'exits zero when the generator succeeds'
    stub="$TMP/gen-ok"; printf '#!/bin/sh\nexit 0\n' >"$stub"; chmod +x "$stub"
    When run command env GENERATE_THEME_BIN="$stub" bash "$HOOK"
    The status should be success
    The stdout should be present
  End
End

# ─────────────────────────────────────────────────────────────────────────────
# run_onchange_after_56 — bat cache failure / unregistered theme is now FATAL
# ─────────────────────────────────────────────────────────────────────────────
Describe 'run_onchange_after_56 (bat cache failure propagation)'
  TPL="$SHELLSPEC_PROJECT_ROOT/home/.chezmoiscripts/run_onchange_after_56-build-bat-cache.sh.tmpl"

  setup() {
    TMP="$(mktemp -d)"
    HOOK="$TMP/hook56.sh"
    BIN="$TMP/bin"
    CFG="$TMP/config"
    mkdir -p "$BIN" "$CFG/bat/themes"
    : >"$CFG/bat/themes/chezmoi-system.tmTheme"
    command chezmoi execute-template <"$TPL" >"$HOOK" 2>/dev/null
    {
      echo '#!/bin/sh'
      echo 'case "$1" in'
      echo '  cache) [ "$BAT_CACHE_OK" = 1 ] && exit 0 || exit 1 ;;'
      echo '  --list-themes) [ "$BAT_LIST_HAS" = 1 ] && echo chezmoi-system; exit 0 ;;'
      echo 'esac'
    } >"$BIN/bat"
    chmod +x "$BIN/bat"
  }
  cleanup() { rm -rf "$TMP"; unset TMP HOOK BIN CFG; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_hook() {
    PATH="$BIN:$PATH" XDG_CONFIG_HOME="$CFG" \
      BAT_CACHE_OK="$1" BAT_LIST_HAS="$2" bash "$HOOK"
  }

  It 'exits non-zero when bat cache --build fails'
    When run run_hook 0 0
    The status should be failure
    The stderr should include 'failed'
  End

  It 'exits non-zero when the theme is not registered after the build'
    When run run_hook 1 0
    The status should be failure
    The stderr should include 'not registered'
  End

  It 'exits zero when the cache builds and the theme is registered'
    When run run_hook 1 1
    The status should be success
    The stdout should include 'Rebuilt bat theme cache'
  End
End
