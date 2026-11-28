# raster::office — the Quick Look thumbnail of an office document.
#
# It runs ql-thumb (custom-builds/ql-thumb) and keeps `qlmanage -t` only as the
# fallback for a machine where ql-thumb was never built: qlmanage registers as
# a foreground app on every run and leaves an icon bouncing in the Dock.
# Both tools are stand-ins here; the real ql-thumb run is preview_spec's
# 'renders a docx first page'.
Describe 'raster::office'
  LIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/raster-common.zsh"

  setup() {
    spec_sandbox
    export RASTER_OUT="$SANDBOX/out.png"
    DOC="$SANDBOX/a.docx"; printf 'PK\003\004rest' >"$DOC"
    # ql-thumb <size> <in> <out.png>; qlmanage -t -s <size> -o <dir> <in>
    spec_stub "$SANDBOX/libexec" ql-thumb 'printf thumb >"$3"'
    spec_stub "$SANDBOX/bin" qlmanage 'printf fallback >"$5/a.docx.png"'
    spec_path_prepend "$SANDBOX/bin"
    export RASTER_QL_THUMB_BIN="$SANDBOX/libexec/ql-thumb"
  }
  # Two stubs per example (three in one), on pooled inodes: exec'd once here.
  Include tests/exec_warm_helper.sh
  BeforeAll 'spec_exec_pool_warm 3'
  BeforeEach 'setup'

  office() {
    zsh -f -c 'source "$1"; raster::office "$2"; print "rc=$? out=$(cat "$RASTER_OUT" 2>/dev/null)"' _ "$LIB" "$1"
    echo "ql-thumb: $(spec_stub_calls "$SANDBOX/libexec" ql-thumb)"
    echo "qlmanage: $(spec_stub_calls "$SANDBOX/bin" qlmanage | cut -d' ' -f1-3)"
  }

  It 'thumbnails with ql-thumb and never starts qlmanage'
    When call office "$DOC"
    The line 1 should equal "rc=0 out=thumb"
    The line 2 should match pattern "ql-thumb: 1600 $DOC */thumb.png"
    The line 3 should equal "qlmanage: "
  End

  It 'falls back to qlmanage where ql-thumb was never built'
    rm -f "$RASTER_QL_THUMB_BIN"
    When call office "$DOC"
    The line 1 should equal "rc=0 out=fallback"
    The line 2 should equal "ql-thumb: "
    The line 3 should equal "qlmanage: -t -s 1600"
  End

  It 'fails without a picture when ql-thumb has no thumbnail for the file'
    spec_stub "$SANDBOX/libexec" ql-thumb 'exit 1'
    When call office "$DOC"
    The line 1 should equal "rc=1 out="
    The line 3 should equal "qlmanage: "
  End

  It 'refuses a file that is not an office container without running either tool'
    printf 'plain text' >"$SANDBOX/b.docx"
    When call office "$SANDBOX/b.docx"
    The line 1 should equal "rc=1 out="
    The line 2 should equal "ql-thumb: "
    The line 3 should equal "qlmanage: "
  End
End
