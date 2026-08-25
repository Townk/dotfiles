Describe 'rip-provider-folder'
  setup() {
    export RIP_SANDBOX=$(mktemp -d)
    export FOLDER_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-folder"
    export ROOT="$RIP_SANDBOX/incoming"
    mkdir -p "$ROOT"
    # Canonicalize: on macOS $TMPDIR sits under /var, itself a symlink to
    # /private/var. fd --absolute-path resolves that symlink when it walks
    # the tree, and so does the provider's own `root="${root:A}"` (needed so
    # its later prefix-strip against fd's output actually matches) — so an
    # unresolved $ROOT would never equal the id/path this spec expects back.
    ROOT="${ROOT:A}"
  }
  cleanup() { rm -rf "$RIP_SANDBOX"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # A book whose directory structure carries the identity: <Author>/<Title>/x.m4b
  mkdirbook() {
    mkdir -p "$ROOT/$1/$2"
    printf 'fake audio\n' > "$ROOT/$1/$2/$2.m4b"
  }

  # `The result of "wc -l"` etc. is not valid shellspec 0.28.1 grammar — that
  # modifier only accepts a defined shell FUNCTION name (shellspec_is_function
  # rejects anything with a space or paren), so each ad-hoc pipeline from the
  # brief becomes a named helper here instead.
  linecount() { wc -l | tr -d ' '; }
  jq_title() { jq -r .title; }
  jq_cover_is_sibling() { jq -r '.cover | endswith("cover.jpg")'; }
  jq_id() { jq -r .id; }
  jq_provider() { jq -r .provider; }
  jq_ids() { jq -c .ids; }

  It 'capabilities: announces itself as an acquiring provider'
    When run zsh "$FOLDER_BIN" capabilities
    The status should equal 0
    The output should include '"name":"folder"'
    The output should include '"can_acquire":true'
  End

  It 'list: an empty root yields no rows and succeeds'
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should equal ""
  End

  It 'list: refuses a root that does not exist rather than reporting an empty library'
    When run zsh "$FOLDER_BIN" list "$ROOT/nope"
    The status should equal 2
    The stderr should include "no such directory"
  End

  It 'list: derives author and title from the directory structure'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"authors":["Ann Leckie"]'
    The output should include '"title":"Ancillary Justice"'
    The output should include '"path":"Ann Leckie/Ancillary Justice"'
    The output should include '"format":"m4b"'
    The output should include '"derived_from":"path"'
  End

  It 'list: one directory is ONE book however many m4b files it holds'
    mkdir -p "$ROOT/Ann Leckie/Ancillary Justice"
    printf 'a\n' > "$ROOT/Ann Leckie/Ancillary Justice/part1.m4b"
    printf 'b\n' > "$ROOT/Ann Leckie/Ancillary Justice/part2.m4b"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function linecount should equal "1"
  End

  It 'list: finds books at any depth, with no recursion limit'
    mkdirbook "deep/deeper/Ann Leckie" "Ancillary Sword"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"title":"Ancillary Sword"'
  End

  It 'list: ignores non-m4b files entirely'
    mkdir -p "$ROOT/Someone/Book"
    printf 'x\n' > "$ROOT/Someone/Book/book.mp3"
    printf 'x\n' > "$ROOT/Someone/Book/notes.txt"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should equal ""
  End

  It 'list: a title with quotes and a dollar sign survives as JSON'
    mkdirbook 'Guns N Roses' 'It''s $HOME: "quoted"'
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_title should equal 'It''s $HOME: "quoted"'
  End

  It 'list: records a sibling cover when one is present, null when not'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'jpg\n' > "$ROOT/Ann Leckie/Ancillary Justice/cover.jpg"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_cover_is_sibling should equal "true"
  End

  It 'list: the id is the book directory, so acquire can find it again'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_id should equal "$ROOT/Ann Leckie/Ancillary Justice"
  End

  It 'list: never claims Audible concepts for a local file'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"plus":false'
    The output should include '"absent":false'
    The output should include '"acquired":true'
  End

  It 'list: reports its own provider identity, never "unknown"'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_provider should equal "folder"
  End

  It 'list: a local file carries no external identity — ids is empty'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The result of function jq_ids should equal "{}"
  End

  It 'list: a sibling pdf is a real local signal — has_pdf true'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    printf 'pdf\n' > "$ROOT/Ann Leckie/Ancillary Justice/companion.pdf"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"has_pdf":true'
  End

  It 'list: no sibling pdf — has_pdf false, never guessed'
    mkdirbook "Ann Leckie" "Ancillary Justice"
    When run zsh "$FOLDER_BIN" list "$ROOT"
    The status should equal 0
    The output should include '"has_pdf":false'
  End
End
