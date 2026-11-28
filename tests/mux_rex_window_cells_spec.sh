# _mux_rx_window_cells — the window's size in cells, which the floats turn
# their cell geometry into fractions with. A layer opens in the session's
# ACTIVE window, so that is the window to measure: a caller in a background
# tab (a job, an agent's pane) may never have been laid out and still reports
# the 80x24 it was born with.
Describe '_mux_rx_window_cells'
  # Stubs an example makes executable run from pooled inodes (spec_helper.sh):
  # their first exec is paid here, once, not inside the first examples.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 1'
  Include home/dot_local/lib/mux-bootstrap.zsh

  setup() {
    WC_TMP=$(mktemp -d)
    cat >"$WC_TMP/rex" <<'EOS'
#!/bin/sh
case " $* " in
  *" session.view "*) cat "$WC_VIEW" ;;
  *" -b block:bg size "*) echo '{"columns":80,"rows":24}' ;;
  *" -b block:fg size "*) echo '{"columns":100,"rows":50}' ;;
  *" -b block:float size "*) echo '{"columns":30,"rows":10}' ;;
esac
exit 0
EOS
    chmod +x "$WC_TMP/rex"
    export MUX_REX_BIN="$WC_TMP/rex" WC_VIEW="$WC_TMP/view.json" REX_SESSION=session:s
    print -r -- '{"active_window_id":"window:2","windows":[
      {"window_id":"window:1","focused_block_id":"block:bg","layers":[{"kind":"tiled","layout":{"rect":[0,0,1,1],"block_id":"block:bg"},"blocks":[{"block_id":"block:bg"}]}]},
      {"window_id":"window:2","focused_block_id":"block:float","layers":[
        {"kind":"tiled","layout":{"rect":[0,0,1,1],"split":{"before":{"rect":[0,0,0.5,1],"block_id":"block:fg"},"after":{"rect":[0.5,0,0.5,1],"block_id":"block:other"}}},"blocks":[{"block_id":"block:fg"},{"block_id":"block:other"}]},
        {"kind":"floating","layout":{"rect":[0,0,1,1],"block_id":"block:float"},"blocks":[{"block_id":"block:float"}]}]}]}' >"$WC_VIEW"
  }
  cleanup() { rm -rf "$WC_TMP"; unset MUX_REX_BIN WC_VIEW REX_SESSION REX_BLOCK; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  It 'measures the window from our own pane when it is in the active window'
    export REX_BLOCK=block:fg
    When call _mux_rx_window_cells
    The output should equal "200 50"
  End

  It 'measures the ACTIVE window when ours is a background tab'
    export REX_BLOCK=block:bg
    When call _mux_rx_window_cells
    The output should equal "200 50"
  End

  It 'measures through a tiled pane when called from a float'
    # A float'"'"'s own rect is a share of its layer, not of the window.
    export REX_BLOCK=block:float
    When call _mux_rx_window_cells
    The output should equal "200 50"
  End

  It 'falls back to our own pane when the active window cannot be measured'
    export REX_BLOCK=block:bg
    print -r -- '{"active_window_id":"window:9","windows":[{"window_id":"window:1","layers":[{"kind":"tiled","layout":{"rect":[0,0,1,1],"block_id":"block:bg"},"blocks":[{"block_id":"block:bg"}]}]}]}' >"$WC_VIEW"
    When call _mux_rx_window_cells
    The output should equal "80 24"
  End

  It 'fails outside a Rex pane'
    unset REX_BLOCK
    When call _mux_rx_window_cells
    The status should be failure
  End
End
