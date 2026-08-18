# Blurb composition. ONE LINE always: the injection target is the originating
# shell pane, where a newline executes. Template choice is driven by endpoint
# CAPABILITY (`web`), never by profile — a self-hosted croc-web serves its own
# browser page, so a recipient there needs no CLI even on a profile that cannot
# use the public store.

Describe 'share:: blurb composition'
  Include home/dot_local/lib/share.zsh

  setup() {
    SB="$SHELLSPEC_TMPBASE/share-blurb"
    rm -rf "$SB"; mkdir -p "$SB"
    SHARE_CONFIG_DIR="$SB"
    SHARE_ENDPOINTS_FILE="$SB/endpoints.toml"
    SHARE_PROFILE=personal
    cat >"$SHARE_ENDPOINTS_FILE" <<'TOML'
[withweb]
store = "https://drop.example.com"
web = true
profiles = ["personal"]

[noweb]
relay = "lab.example.com:9009"
web = false
profiles = ["personal"]

[custom]
store = "https://c.example.com"
web = true
message = "%name is at %url"
profiles = ["personal"]

[starts]
store = "https://s.example.com"
web = true
message = "%url is %name"
profiles = ["personal"]

[percent]
store = "https://p.example.com"
web = true
message = "%name is 100% done: %url"
profiles = ["personal"]
TOML
  }
  BeforeEach 'setup'

  It 'renders bytes as a human size'
    When call share::human_size 4404019
    The output should equal '4.2 MB'
  End

  It 'labels a single file with its basename and size'
    printf '0123456789' >"$SB/Report.pdf"
    When call share::label "$SB/Report.pdf"
    The output should equal 'Report.pdf (10 B)'
  End

  It 'collapses several files into a count and total'
    printf '0123456789' >"$SB/a.bin"
    printf '0123456789' >"$SB/b.bin"
    When call share::label "$SB/a.bin" "$SB/b.bin"
    The output should equal '2 files (20 B)'
  End

  It 'uses the web template for a web-capable endpoint'
    When call share::blurb withweb web 'Report.pdf (4.2 MB)' \
      'https://drop.example.com/s/a1#v1.k' 'Aug 20' '1 download'
    The output should equal 'Report.pdf (4.2 MB) → https://drop.example.com/s/a1#v1.k · expires Aug 20, 1 download'
  End

  It 'adds the install hint for an endpoint with no browser page'
    When call share::blurb noweb cli 'Report.pdf (4.2 MB)' \
      'croc-store-v1.aaa' 'Aug 20' '1 download'
    The output should include 'croc-store-v1.aaa'
    The output should include 'get croc: github.com/schollz/croc'
    The output should include 'expires Aug 20'
  End

  # The live line is the product (amendment D3): it gets pasted into a chat
  # message, so it must serve `share get`, a croc-only recipient, and a human
  # reading it, all at once. The retired template said "run: croc <phrase> ·
  # I'm holding it open" and was printed AFTER croc exited — i.e. after the
  # transfer it claimed to be holding open had closed.
  It 'renders the live line as a runnable croc command'
    When call share::blurb withweb live 'Report.pdf (4.2 MB)' \
      '7-truck-mango-basil' '' ''
    The output should equal 'Report.pdf (4.2 MB) — receive with:  croc 7-truck-mango-basil'
  End

  # A self-hosted relay MUST appear in the line. The phrase alone is enough
  # only on croc's built-in relay and on a multicast LAN; for any other relay
  # the recipient has no way to reach the sender and the transfer simply never
  # happens. `noweb` carries relay = lab.example.com:9009.
  It 'names a self-hosted relay in the live line, or the recipient cannot connect'
    When call share::blurb noweb live 'Report.pdf (4.2 MB)' \
      '7-truck-mango-basil' '' ''
    The output should equal 'Report.pdf (4.2 MB) — receive with:  croc --relay lab.example.com:9009 7-truck-mango-basil'
  End

  It 'always emits exactly one line'
    When call share::blurb withweb web 'R.pdf (1 B)' 'https://x/s/a#v1.k' 'Aug 20' '1 download'
    The lines of output should equal 1
  End

  It 'honours a per-endpoint message override'
    When call share::blurb custom web 'R.pdf (1 B)' 'https://c.example.com/s/a#v1.k' 'Aug 20' '1 download'
    The output should equal 'R.pdf (1 B) is at https://c.example.com/s/a#v1.k'
  End

  # Regression for the sequential-replace bug: a label containing literal
  # "%url" text must not be re-substituted when the %url token is filled in
  # right after it. Fails against the old chain-of-${out//...} implementation.
  It 'does not re-substitute a label that itself contains %url'
    When call share::blurb withweb web '%url (10 B)' \
      'https://x/s/a#v1.k' 'Aug 20' '1 download'
    The output should equal '%url (10 B) → https://x/s/a#v1.k · expires Aug 20, 1 download'
    The lines of output should equal 1
  End

  It 'does not re-substitute a label that itself contains %token'
    When call share::blurb noweb cli '%token (10 B)' \
      'croc-store-v1.aaa' 'Aug 20' '1 download'
    The output should equal '%token (10 B) → croc-store-v1.aaa · get croc: github.com/schollz/croc · expires Aug 20'
    The lines of output should equal 1
  End

  It 'renders correctly when the template starts with a token'
    When call share::blurb starts web 'R.pdf (1 B)' \
      'https://s.example.com/x' 'Aug 20' '1 download'
    The output should equal 'https://s.example.com/x is R.pdf (1 B)'
    The lines of output should equal 1
  End

  It 'leaves a literal % that is not a known token untouched'
    When call share::blurb percent web 'R.pdf (1 B)' \
      'https://p.example.com/x' 'Aug 20' '1 download'
    The output should equal 'R.pdf (1 B) is 100% done: https://p.example.com/x'
    The lines of output should equal 1
  End

  It 'fails closed on a nonexistent path instead of reporting 0 B'
    When run share::label "$SB/nosuch.pdf"
    The status should be failure
    The stderr should include 'nosuch.pdf'
  End
End
