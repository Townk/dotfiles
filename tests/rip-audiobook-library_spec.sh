# rip-audiobook, part 2 of 4 — sidecars, work uids, the worker, import, editions and backfill.
# Hermetic: sandboxed staging, fake LibationCli (RIP_LIBATION_BIN), fake ssh
# (RIP_SSH_BIN), no network, no GUI. The sandbox and shared helpers live in
# tests/rip_audiobook_helper.sh.
Describe 'rip audiobooks'
  RIPLIB="$SHELLSPEC_PROJECT_ROOT/home/dot_local/lib/rip.zsh"
  PROVIDER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-libation"
  ABS_BIN="$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-abs-authors"
  Include tests/rip_helper.sh
  Include tests/rip_audiobook_helper.sh
  BeforeEach 'setup'
  AfterEach 'cleanup'

  # --- work: an object, protected across a second push (Task 1) ------------
  #
  # rip::_book_sidecar is the composer EVERY push runs (rip::_enrich_audiobooks
  # calls it once per staged book dir, right before the rsync). It merges the
  # freshly composed sidecar over whatever ALREADY sits at that path with the
  # old file winning at every depth for a non-null value — the same rule that
  # protects `ids` across a retried/re-enriched push. `work` has carried that
  # same protection since it was introduced, but always as `null`, so nothing
  # has ever exercised it: this pins it now that `work` is about to become an
  # object a later task actually writes.
  work_book_sidecar_meta() {
    printf '%s\n' '{"title":"B","authors":["A"],"provider":"libation","format":"m4b"}' \
      > "$RIP_SANDBOX/work-meta.json"
  }

  It 'sidecar: a composed row with no edition still writes work: null — byte-identical to today'
    work_book_sidecar_meta
    mkdir -p "$RIP_SANDBOX/work-book-a"
    When run zsh -c "source $RIPLIB \
      && rip::_book_sidecar '$RIP_SANDBOX/work-book-a' '$RIP_SANDBOX/work-meta.json' >/dev/null \
      && jq -c '.work' '$RIP_SANDBOX/work-book-a/.fleet-book.json'"
    The status should equal 0
    The output should equal "null"
  End

  It 'sidecar: work already recorded as an object survives a second push unchanged'
    work_book_sidecar_meta
    mkdir -p "$RIP_SANDBOX/work-book-b"
    When run zsh -c "source $RIPLIB
      rip::_book_sidecar '$RIP_SANDBOX/work-book-b' '$RIP_SANDBOX/work-meta.json' >/dev/null
      # Simulate a work already resolved on this staged sidecar — nothing in
      # this task sets it yet (that is Task 3); this stands in for it so the
      # merge that will protect it has something non-null to protect.
      jq '.work = {uid:\"9f1c2a4e-1111-4b22-8aa0-abc123456789\",edition:\"Full Cast\"}' \
        '$RIP_SANDBOX/work-book-b/.fleet-book.json' > '$RIP_SANDBOX/work-book-b/.fleet-book.json.next'
      mv '$RIP_SANDBOX/work-book-b/.fleet-book.json.next' '$RIP_SANDBOX/work-book-b/.fleet-book.json'
      # The second push: same meta, same composer — the old, non-null work
      # must win over the freshly composed work: null.
      rip::_book_sidecar '$RIP_SANDBOX/work-book-b' '$RIP_SANDBOX/work-meta.json' >/dev/null
      jq -c '.work' '$RIP_SANDBOX/work-book-b/.fleet-book.json'"
    The status should equal 0
    The output should equal '{"uid":"9f1c2a4e-1111-4b22-8aa0-abc123456789","edition":"Full Cast"}'
  End

  # --- work: the worker resolves the uid an edition shares (Task 3) ---------
  #
  # An item carrying a non-empty `edition` is a DIFFERENT EDITION of a book
  # cantina may already hold. Its `path` already carries the " (<Edition>)"
  # suffix — the panel composes it — so the base book's path is that path with
  # that exact suffix removed. NEVER a general parenthesis parse: a book
  # legitimately titled "Something (Unabridged)" with no edition set must be
  # left completely alone, which the no-edition example at the end of this
  # section pins.
  #
  # The uid is resolved against the base book's stored sidecar: reused when it
  # has one, minted and written BACK to it when it has none, minted fresh when
  # no such book is stored (design doc S4). The write-back is the only place
  # in this phase that touches ANOTHER book's sidecar — the file holding the
  # only copy of that book's identity — so it must be additive and must never
  # overwrite a uid that is already there.

  wu_ed_path()   { printf '%s' "$RIP_SANDBOX/server/audiobooks/A/B (Full Cast)/.fleet-book.json"; }
  wu_base_path() { printf '%s' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"; }

  # wu_base <uid-or-empty> — the stored BASE book, schema-shaped and pretty,
  # carrying a work uid only when one is given. Deliberately rich (a subtitle,
  # a real asin, companions) so "additive" has something to be additive about.
  wu_base() {
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    jq -n --arg u "$1" '{schema:1,kind:"audiobook",title:"B",subtitle:"The Sub",
      authors:["A"],narrators:["N"],series:null,duration_s:1200,language:"english",
      abridged:false,published:"2013-09-24T07:00:00",
      ids:{"audible.asin":"B0BASE0001","fleet.uid":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"},
      work:(if $u == "" then null else {uid:$u,edition:null} end),
      companions:[],
      source:{provider:"libation",provider_version:"13.7.10",acquired_utc:null,format:"m4b"}}' \
      > "$(wu_base_path)"
  }

  # wu_plan <edition|omit> — a one-item folder plan whose path ALREADY carries
  # the " (Full Cast)" suffix, exactly as the panel composes it.
  wu_plan() {
    mkdir -p "$RIP_SANDBOX/incoming/Full"
    printf 'full cast bytes\n' > "$RIP_SANDBOX/incoming/Full/full.m4b"
    if [ "$1" = "omit" ]; then
      jq -nc --arg id "$RIP_SANDBOX/incoming/Full/full.m4b" \
        '{provider:"folder",items:[{id:$id,path:"A/B (Full Cast)",title:"B",
          authors:["A"],provider:"folder"}]}' > "$RIP_SANDBOX/plan.json"
    else
      jq -nc --arg id "$RIP_SANDBOX/incoming/Full/full.m4b" --arg e "$1" \
        '{provider:"folder",items:[{id:$id,path:"A/B (Full Cast)",title:"B",
          authors:["A"],provider:"folder",edition:$e}]}' > "$RIP_SANDBOX/plan.json"
    fi
  }

  wu_ed_work()   { jq -c '.work' "$(wu_ed_path)" 2>/dev/null; }
  wu_ed_uid()    { jq -r '.work.uid // ""' "$(wu_ed_path)" 2>/dev/null; }
  wu_base_sha()  { shasum -a 256 "$(wu_base_path)" | cut -d' ' -f1; }
  # The NON-work bytes of the base sidecar. `jq 'del(.work)'` renders both
  # sides through one deterministic pretty-printer, so this compares the
  # actual TEXT of everything the write-back was not allowed to touch — an
  # assertion that merely re-read a field would pass against a rewrite that
  # happened to preserve it.
  wu_base_nonwork() { jq 'del(.work)' "$(wu_base_path)" 2>/dev/null; }
  wu_base_work()    { jq -c '.work' "$(wu_base_path)" 2>/dev/null; }
  wu_is_uuid4() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      && echo "uuidv4" || echo "NOT A UUIDV4: $1"
  }
  wu_ed_uid_shape() { wu_is_uuid4 "$(wu_ed_uid)"; }
  # The whole point of the mint-and-write-back branch: BOTH books end up
  # carrying the SAME uid, or the two editions never group.
  wu_uids_shared() {
    e=$(wu_ed_uid); b=$(jq -r '.work.uid // ""' "$(wu_base_path)" 2>/dev/null)
    if [ -n "$e" ] && [ "$e" = "$b" ]; then wu_is_uuid4 "$e"; else echo "edition=$e base=$b"; fi
  }
  # Every stored file's path and content EXCEPT the new edition's own book
  # dir — "nothing was written to any other path", proved against the whole
  # sandbox server tree rather than against the absence of a log line.
  wu_digest_but_edition() {
    ( cd "$RIP_SANDBOX/server" && find . -type f | grep -v '/A/B (Full Cast)/' \
        | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s\n' "$f"; shasum -a 256 "$f" | cut -d' ' -f1
          done ) | shasum -a 256 | cut -d' ' -f1
  }

  It 'work uid: an edition whose base book already anchors a work REUSES that uid'
    wu_base "9f1c2a4e-2222-4b22-8aa0-abc123456789"
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_work should equal '{"uid":"9f1c2a4e-2222-4b22-8aa0-abc123456789","edition":"Full Cast"}'
  End

  It 'work uid: a base book with no uid is MINTED one, written back additively, and shared'
    wu_base ""
    wu_plan "Full Cast"
    before=$(wu_base_nonwork)
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_uids_shared should equal "uuidv4"
    # ...and the base book anchors the work rather than claiming the edition
    # label, which belongs to the book that was just ripped.
    The result of function wu_base_work should include '"edition":null'
    # ADDITIVE: every other key of that sidecar comes back byte-identical.
    The result of function wu_base_nonwork should equal "$before"
  End

  It 'work uid: no base book stored mints a fresh uid and writes to no other path'
    # A bystander book, so "nothing else was written" is measured against a
    # non-empty tree.
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Z/Other"
    printf 'other\n' > "$RIP_SANDBOX/server/audiobooks/Z/Other/Other.m4b"
    wu_plan "Full Cast"
    before=$(wu_digest_but_edition)
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_uid_shape should equal "uuidv4"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
    The result of function wu_digest_but_edition should equal "$before"
  End

  It 'work uid: an existing non-null work.uid is NEVER overwritten'
    # Deliberately irregular formatting and a pre-existing edition label — a
    # write that merely re-serialized to the same parsed value would still
    # fail this, because the check is on the raw bytes.
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,   "kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":{"uid":"11111111-1111-4111-8111-111111111111","edition":"Abridged"},"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    before=$(wu_base_sha)
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_sha should equal "$before"
    The result of function wu_ed_uid should equal "11111111-1111-4111-8111-111111111111"
  End

  # The STRUCTURAL guard, in isolation. A uid of the wrong type is non-null,
  # so it must not be overwritten — but it is not a uid either, so it must
  # not be reused. The read-side check refuses to reuse it (it is not a
  # string) and hands control to the write path, where the jq program's own
  # `empty` branch is the only thing left standing between a hand-edited
  # sidecar and a rewrite. Nothing may be written; the edition gets its own
  # fresh uid and the operator is told the two will not group.
  It 'work uid: a work.uid of the wrong type is neither reused nor overwritten'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":{"uid":12345},"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    before=$(wu_base_sha)
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_sha should equal "$before"
    The result of function wu_ed_uid_shape should equal "uuidv4"
    The stderr should include "could not record the shared work uid"
  End

  # `work` REALLY CAN ARRIVE AS AN ARRAY: Hammerspoon encodes an empty Lua
  # table as `[]`, not `{}` (see _RIP_JQ_IDS_DEF for the measurement), and a
  # sidecar written from a plan that round-tripped through the panel can
  # carry it. `.work.uid` RAISES on an array and `[] | del(.uid)` raises too,
  # so without the `_work_obj` coercion on BOTH sides the write-back composes
  # nothing and the two editions silently never group. The array means "no
  # work recorded", which is exactly the mint-and-write-back case.
  It 'work uid: a stored "work": [] is treated as no work at all and is filled'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":[],"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_uids_shared should equal "uuidv4"
    The result of function wu_base_work should include '"edition":null'
  End

  # `false` is the ONE value jq's `//` treats as empty besides null, so
  # `($w.uid // "") != ""` let it through into the write branch while `0`,
  # `12345`, `[]` and `{}` were all refused (review finding, 2026-08-26). No
  # producer in this codebase emits it — this example is here so the refusal
  # is total by construction rather than total for the values that happen to
  # occur.
  It 'work uid: a work.uid of false is non-null, and is not overwritten either'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf 'base bytes\n' > "$RIP_SANDBOX/server/audiobooks/A/B/B.m4b"
    printf '%s' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{},"work":{"uid":false},"source":{"provider":"libation"}}' \
      > "$(wu_base_path)"
    before=$(wu_base_sha)
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_sha should equal "$before"
    The result of function wu_ed_uid_shape should equal "uuidv4"
    The stderr should include "could not record the shared work uid"
  End

  # TWO EDITIONS OF ONE WORK IN A SINGLE BATCH (review finding, 2026-08-26).
  # Uid resolution reads the BASE book from the server, and a base that is
  # being ripped in this same batch — or, as here, that cantina simply does
  # not hold — is not there to read, so both editions fell through to "mint
  # fresh" and landed with DIFFERENT uids. Both then carry a non-null `work`,
  # which makes neither a --backfill-work-uid candidate ever again, and there
  # is no repair verb: the split is permanent short of a hand edit on the
  # server. The worker memoizes per base path across the acquire loop.
  wu_two_editions_share() {
    u1=$(jq -r '.work.uid // ""' "$RIP_SANDBOX/server/audiobooks/A/B (Full Cast)/.fleet-book.json" 2>/dev/null)
    u2=$(jq -r '.work.uid // ""' "$RIP_SANDBOX/server/audiobooks/A/B (Unabridged)/.fleet-book.json" 2>/dev/null)
    if [ -n "$u1" ] && [ "$u1" = "$u2" ]; then wu_is_uuid4 "$u1"; else echo "full=$u1 unabridged=$u2"; fi
  }
  wu_two_editions_labels() {
    jq -r '.work.edition' "$RIP_SANDBOX/server/audiobooks/A/B (Full Cast)/.fleet-book.json" 2>/dev/null
    jq -r '.work.edition' "$RIP_SANDBOX/server/audiobooks/A/B (Unabridged)/.fleet-book.json" 2>/dev/null
  }
  It 'work uid: two editions of one UNSTORED work in a single batch share one uid'
    mkdir -p "$RIP_SANDBOX/incoming/Full" "$RIP_SANDBOX/incoming/Abr"
    printf 'full cast bytes\n' > "$RIP_SANDBOX/incoming/Full/full.m4b"
    printf 'abridged bytes\n' > "$RIP_SANDBOX/incoming/Abr/abr.m4b"
    jq -nc --arg f "$RIP_SANDBOX/incoming/Full/full.m4b" --arg a "$RIP_SANDBOX/incoming/Abr/abr.m4b" \
      '{provider:"folder",items:[
         {id:$f,path:"A/B (Full Cast)",title:"B",authors:["A"],provider:"folder",edition:"Full Cast"},
         {id:$a,path:"A/B (Unabridged)",title:"B",authors:["A"],provider:"folder",edition:"Unabridged"}]}' \
      > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_two_editions_share should equal "uuidv4"
    # ...one work, two DIFFERENT edition labels. Sharing a uid must not be
    # achieved by sharing the whole object.
    The result of function wu_two_editions_labels should equal "Full Cast
Unabridged"
    The path "$RIP_SANDBOX/server/audiobooks/A/B" should not be exist
  End

  # "COULD NOT ASK CANTINA" IS NOT "NO BASE BOOK STORED" (review finding,
  # 2026-08-26). rip::_remote_sidecar_json's contract is tri-state and its
  # own header says "Unknown must never collapse into absent" — but the read
  # path treated rc 1 (confirmed absent) and rc 2 (never asked) identically:
  # mint fresh, rc 0, stderr EMPTY. The two outcomes look the same on disk
  # and mean opposite things. Absent is legal and expected (the operator is
  # importing the Full Cast edition first); unknown means the base book may
  # be sitting on cantina RIGHT NOW with a uid this rip is about to diverge
  # from, permanently, because both books then carry a non-null `work` and
  # neither is a --backfill-work-uid candidate again. The write-back failure
  # path already warns about exactly this consequence; the read path, which
  # produces the same one, said nothing at all.
  #
  # PAIRED, deliberately: the warning has to distinguish, so the absent case
  # must stay silent. An example that only asserted the warning would pass
  # against a function that warned unconditionally — which would train the
  # operator to ignore the one line that matters.
  wu_uid_shape_of_output() { wu_is_uuid4 "$1"; }

  It 'work uid: a server that could not be asked warns before minting a fresh uid'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_ab_work_uid_for 'A/B'"
    The status should equal 0
    The result of function wu_uid_shape_of_output should equal "uuidv4"
    The stderr should include "could not read"
    The stderr should include "A/B"
    The stderr should include "will not group as one work"
  End

  It 'work uid: a base book the server CONFIRMS is absent mints quietly'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    # `cat` on a missing file exits 1, and ssh hands that status back: this
    # is the "no such book is stored" branch, which is legal and must not
    # warn about anything.
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_ab_work_uid_for 'A/B'"
    The status should equal 0
    The result of function wu_uid_shape_of_output should equal "uuidv4"
    The stderr should equal ""
  End

  # A BASE BOOK AND ITS OWN EDITION IN ONE BATCH (review finding,
  # 2026-08-26). The memo above only fires for items that CARRY an edition:
  # the whole uid block sits inside `if [[ -n "$edition" ]]`, and the index
  # patch only ever touched the edition's own row — so a no-edition base item
  # in the same plan recorded no `work` at all. It landed with `work: null`
  # while its edition landed with a uid, the later --backfill-work-uid sweep
  # minted the base a DIFFERENT one, and from then on both carry a non-null
  # `work` so neither is ever a candidate again: two unrelated works in
  # `--editions`, repairable only by hand on the server.
  #
  # And it is the NATURAL flow, not a corner: two files that both derive
  # A/B collide in the panel's path-keyed rippable() dedupe, so setting an
  # Edition on ONE of them is the only way to rip both at once.
  #
  # The patch is keyed on `.path`, so BOTH ORDERS are pinned — the edition
  # can resolve before or after the base is even looked at.
  wu_base_and_edition_share() {
    ub=$(jq -r '.work.uid // ""' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" 2>/dev/null)
    ue=$(jq -r '.work.uid // ""' "$RIP_SANDBOX/server/audiobooks/A/B (Full Cast)/.fleet-book.json" 2>/dev/null)
    if [ -n "$ub" ] && [ "$ub" = "$ue" ]; then wu_is_uuid4 "$ub"; else echo "base=$ub edition=$ue"; fi
  }
  # The base is the ANCHOR: it shares the uid, never the edition label. Read
  # as a SHAPE, not as `.work.edition` — on a book with `work: null` that
  # expression prints "null" too, so an assertion written that way would pass
  # against the very defect these examples exist for.
  wu_work_shape() {
    jq -c 'if (.work // null) == null then "no work at all"
           else {has_uid: ((.work.uid // "") != ""), edition: .work.edition} end' \
      "$1" 2>/dev/null
  }
  wu_base_and_edition_labels() {
    wu_work_shape "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    wu_work_shape "$RIP_SANDBOX/server/audiobooks/A/B (Full Cast)/.fleet-book.json"
  }
  # <first-item> — the two-item plan, in the given order. Distinct bytes per
  # file: identical ones would be refused by the sha256 dedupe first and the
  # second book would never be acquired at all.
  wu_pair_plan() {
    mkdir -p "$RIP_SANDBOX/incoming/Base" "$RIP_SANDBOX/incoming/Full"
    printf 'base bytes\n' > "$RIP_SANDBOX/incoming/Base/base.m4b"
    printf 'full cast bytes\n' > "$RIP_SANDBOX/incoming/Full/full.m4b"
    jq -nc --arg b "$RIP_SANDBOX/incoming/Base/base.m4b" --arg f "$RIP_SANDBOX/incoming/Full/full.m4b" --arg first "$1" \
      '{base:{id:$b,path:"A/B",title:"B",authors:["A"],provider:"folder"},
        ed:{id:$f,path:"A/B (Full Cast)",title:"B",authors:["A"],provider:"folder",edition:"Full Cast"}}
       | {provider:"folder", items:(if $first == "base" then [.base,.ed] else [.ed,.base] end)}' \
      > "$RIP_SANDBOX/plan.json"
  }

  It 'work uid: a base book and its edition in ONE batch share a uid (base first)'
    wu_pair_plan base
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_and_edition_share should equal "uuidv4"
    The result of function wu_base_and_edition_labels should equal '{"has_uid":true,"edition":null}
{"has_uid":true,"edition":"Full Cast"}'
  End

  It 'work uid: a base book and its edition in ONE batch share a uid (edition first)'
    wu_pair_plan edition
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_base_and_edition_share should equal "uuidv4"
    The result of function wu_base_and_edition_labels should equal '{"has_uid":true,"edition":null}
{"has_uid":true,"edition":"Full Cast"}'
  End

  # THE RE-KEY MOVES THE TARGET (review finding, 2026-08-26, round 2). The
  # anchor above matches the base row by the path THE PLAN gave it — but the
  # reconcile step later in this same loop rewrites that key to the folder
  # that actually landed ("... landed as ... — re-keying the plan identity").
  # Once the base item has been acquired, its row no longer answers to the
  # planned path, so the edition's anchor matches nothing and the base ships
  # with `work: null`: exactly the permanent split the anchor exists to
  # prevent, reappearing whenever the base is acquired FIRST.
  #
  # THE PROVIDER MUST BE ONE THAT RE-KEYS, or this cannot fail. The folder
  # provider honours the relpath the worker hands it as a third argument, so
  # a folder plan never re-keys and every existing example here is blind to
  # this. rip-provider-libation's dispatcher forwards only its own first two
  # post-shift args to cmd_acquire, so that third argument is DISCARDED and
  # Libation lands the book wherever it likes — here, with the ":" sanitized
  # out of the folder name, which is the shape the live "landed as" warnings
  # in this subsystem's ledger already have. Same class as the NFC bug that
  # APFS hid: green suite, broken on the only provider that reaches it.
  wu_rekey_plan() { # <first: base|edition>
    jq -nc --arg first "$1" \
      '{base:{id:"BASEID",path:"A/B: Sub",title:"B",subtitle:"Sub",
              ids:{"audible.asin":"BASEID"},provider:"libation",format:"m4b"},
        ed:{id:"EDID",path:"A/B: Sub (Full Cast)",title:"B",subtitle:"Sub",
            ids:{"audible.asin":"EDID"},provider:"libation",format:"m4b",edition:"Full Cast"}}
       | {provider:"libation", items:(if $first == "base" then [.base,.ed] else [.ed,.base] end)}' \
      > "$RIP_SANDBOX/plan.json"
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s
' "$*" >> "$RIP_SANDBOX/libation.log"
[ "$1" = "liberate" ] || exit 0
id=""; books=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id) id="$2" ;;
    -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;;
  esac
  shift
done
[ -n "$books" ] || { echo "no Books override" >&2; exit 1; }
case "$id" in
  BASEID) d="$books/A/B - Sub" ;;
  EDID)   d="$books/A/B - Sub (Full Cast)" ;;
  *) echo "unknown id" >&2; exit 1 ;;
esac
mkdir -p "$d"
printf 'audio-%s\n' "$id" > "$d/book.m4b"
echo "Completed"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
  }
  # Read from the LANDED paths, not the planned ones — that is where the two
  # books actually are once the provider has had its way with the name.
  wu_rekey_share() {
    ub=$(jq -r '.work.uid // ""' "$RIP_SANDBOX/server/audiobooks/A/B - Sub/.fleet-book.json" 2>/dev/null)
    ue=$(jq -r '.work.uid // ""' "$RIP_SANDBOX/server/audiobooks/A/B - Sub (Full Cast)/.fleet-book.json" 2>/dev/null)
    if [ -n "$ub" ] && [ "$ub" = "$ue" ]; then wu_is_uuid4 "$ub"; else echo "base=$ub edition=$ue"; fi
  }
  wu_rekey_shapes() {
    wu_work_shape "$RIP_SANDBOX/server/audiobooks/A/B - Sub/.fleet-book.json"
    wu_work_shape "$RIP_SANDBOX/server/audiobooks/A/B - Sub (Full Cast)/.fleet-book.json"
  }

  It 'work uid: a base book RE-KEYED by its provider is still anchored (base first)'
    wu_rekey_plan base
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    # The re-key is what this example is about: assert it HAPPENED, or a
    # provider fake that quietly landed the planned path would make the
    # whole example pass without ever exercising the case.
    The stderr should include "re-keying the plan identity"
    The result of function wu_rekey_share should equal "uuidv4"
    The result of function wu_rekey_shapes should equal '{"has_uid":true,"edition":null}
{"has_uid":true,"edition":"Full Cast"}'
  End

  # The order that already worked — the edition resolves before the base has
  # been acquired, so the planned key is still live. Pinned so the added
  # alternative cannot break it.
  It 'work uid: a base book RE-KEYED by its provider is still anchored (edition first)'
    wu_rekey_plan edition
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should include "re-keying the plan identity"
    The result of function wu_rekey_share should equal "uuidv4"
    The result of function wu_rekey_shapes should equal '{"has_uid":true,"edition":null}
{"has_uid":true,"edition":"Full Cast"}'
  End

  # The anchor patch must never reach a book that is NOT in this plan, and
  # must never overwrite a work another edition already recorded. Here the
  # base is stored on the server with its own uid and is NOT part of the
  # batch: the existing read path reuses that uid (it must), and the stored
  # sidecar stays byte-identical — the anchoring patch is an in-plan,
  # meta-index-only operation.
  It 'work uid: the in-plan anchor never rewrites a stored base book'
    wu_base "9f1c2a4e-3333-4b22-8aa0-abc123456789"
    before=$(wu_base_sha)
    wu_plan "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_uid should equal "9f1c2a4e-3333-4b22-8aa0-abc123456789"
    The result of function wu_base_sha should equal "$before"
  End

  # THE NO-EDITION CASE, on the very path that would tempt a parenthesis
  # parser: the book is titled "B (Full Cast)" and the operator set no
  # edition. Nothing may be resolved, nothing read, nothing written — the
  # sidecar is byte-identical to what today's worker produces, `work: null`.
  It 'work uid: an item with no edition is left exactly as it is — no parenthesis parsing'
    wu_base "9f1c2a4e-2222-4b22-8aa0-abc123456789"
    wu_plan omit
    before=$(wu_base_sha)
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The result of function wu_ed_work should equal "null"
    The result of function wu_base_sha should equal "$before"
  End

  It 'worker: one failing acquire does not abort the batch'
    printf '%s\n' '{"provider":"libation","items":[{"id":"BAD","path":"A/Bad","title":"Bad"},{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
case "$*" in
  *"--id BAD"*) echo "download failed" >&2; exit 4 ;;
esac
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    The stderr should include "acquire failed"
    The output should include 'download failed'
  End

  It 'worker: re-keys the identity when the folder that landed differs'
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart: The Reckoners, Book 1","title":"Steelheart","subtitle":"The Reckoners, Book 1","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"]]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I"]'
    The stderr should include "re-keying"
  End

  # The re-key writes the LANDED folder name (raw directory-listing bytes)
  # as the index's new lookup key, but rip::_book_meta_for (the index's only
  # reader) NFC-normalizes its own query key before matching .path. A
  # provider that lands an NFD-decomposed name — composed (NFC) in the plan,
  # decomposed (NFD) on disk, byte-explicit here the same way the ssh/--have
  # example above is (review finding, same bug class as 21322287) — must
  # still re-key to something the NFC-normalized lookup can find, or the
  # sidecar silently falls back to the path-derived minimal identity.
  #
  # PLATFORM NOTE (found while verifying this example can fail against the
  # un-normalized code): unlike the ssh/--have example above, this step has
  # no remote/byte-strict branch to exercise instead — `landed` comes ONLY
  # from a local zsh glob (`*(N/om)`) over the acquire destination. On this
  # fleet's zsh (verified on both the custom build AND stock /bin/zsh 5.9),
  # that glob itself already returns NFC-composed names for an on-disk NFD
  # directory — confirmed by comparison: `ls`/`find`/python's listdir() all
  # return the raw NFD bytes for the SAME directory, only zsh's own glob
  # normalizes. So on THIS platform `${landed[1]:t}` is already NFC before
  # rip::_nfc ever runs, and this example cannot itself fail against a
  # broken (un-normalized) re-key — same caveat as the ab_have example
  # above, for a different underlying reason. The explicit rip::_nfc call
  # is kept anyway: it is the consistent, defensive contract every other
  # filesystem-derived identity lookup key in this file already follows,
  # and it is what protects a zsh build or platform (e.g. the project's
  # Linux dev-shell) whose glob does NOT do this normalization. This
  # example still guards the full round trip end-to-end (NFD-on-disk name
  # in, correct plan identity out) even though it cannot pin the specific
  # line.
  It 'worker: the reconcile re-key is NFC-normalized, so an NFD landed name still resolves'
    nfc=$(printf 'Ant\xc3\xb4nio')
    nfd=$(printf 'Anto\xcc\x82nio')
    printf '%s\n' "{\"provider\":\"libation\",\"items\":[{\"id\":\"B00ECDZ08I\",\"path\":\"Brandon Sanderson/${nfc}: The Reckoners, Book 1\",\"title\":\"${nfc}\",\"subtitle\":\"The Reckoners, Book 1\",\"ids\":{\"audible.asin\":\"B00ECDZ08I\"},\"provider\":\"libation\",\"format\":\"m4b\"}]}" > "$RIP_SANDBOX/plan.json"
    cat > "$RIP_SANDBOX/LibationCli" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$RIP_SANDBOX/libation.log"
books=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o|--override) case "\$2" in Books=*) books="\${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "\$books/Brandon Sanderson/${nfd}"
printf 'audio\n' > "\$books/Brandon Sanderson/${nfd}/${nfd}.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json >/dev/null && jq -c '[.subtitle,.ids[\"audible.asin\"]]' '$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/${nfc}/.fleet-book.json'"
    The status should equal 0
    The output should equal '["The Reckoners, Book 1","B00ECDZ08I"]'
    The stderr should include "re-keying"
  End

  It 'worker: the queued plan copy is removed once read'
    cp "$RIP_SANDBOX/plan.json" "$RIP_STAGING_ROOT/.work/ab-plans/x.json" 2>/dev/null || mkdir -p "$RIP_STAGING_ROOT/.work/ab-plans"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_STAGING_ROOT/.work/ab-plans/x.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_STAGING_ROOT/.work/ab-plans/x.json"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/.work/ab-plans/x.json" should not be exist
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # --- the acquire's OUTCOME, not its exit code -----------------------------
  #
  # LibationCli exits 0 for a title whose Audible Plus licence has lapsed,
  # having liberated nothing at all (reproduced live 2026-08-24 with
  # Pierce Brown/Red Rising). The worker's only failure signal used to be
  # that rc, so it called the item a success, the push found no new files,
  # and the operator got a "ripping complete" toast for a book that never
  # arrived — this subsystem's NINTH "success asserted from control flow
  # reaching a line" defect. These examples pin the fix: the claim rests on
  # files that exist.

  # locked_libation <id> — a fake LibationCli whose liberate EXITS 0 and
  # writes nothing for <id>, and lands Steelheart for anything else. That
  # asymmetry is the point: the batch must survive the silent no-op.
  locked_libation() {
    cat > "$RIP_SANDBOX/LibationCli" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$RIP_SANDBOX/libation.log"
case "\$*" in
  *"--id $1"*) echo "Done. Downloaded 0 books."; exit 0 ;;
esac
books=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o|--override) case "\$2" in Books=*) books="\${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "\$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "\$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
  }

  It 'worker: an acquire that exits 0 but produces no files is reported as a failure, and the batch continues'
    locked_libation LOCKED
    printf '%s\n' '{"provider":"libation","items":[{"id":"LOCKED","path":"Pierce Brown/Red Rising","title":"Red Rising"},{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    # the failure is the RUN's exit code, not just a log line
    The status should not equal 0
    The stderr should include "acquire produced no files for Pierce Brown/Red Rising"
    # …and the rest of the batch still landed on the server
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/Steelheart.m4b" should be exist
    # NEVER a cause we did not establish: this row carries no plus/absent, so
    # the message must not blame a licence.
    The stderr should not include "licence"
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # A book directory that EXISTS but holds no audio is the same failure: a
  # provider that created its destination and then bailed must not be read as
  # a success by the mere presence of the folder.
  It 'worker: an empty book directory is not a successful acquire'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Pierce Brown/Red Rising"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"LOCKED","path":"Pierce Brown/Red Rising","title":"Red Rising"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The stderr should include "acquire produced no files for Pierce Brown/Red Rising"
    The output should include 'rip: nothing settled to push for audiobooks (age gate 0s)'
  End

  # The diagnostic, built from the ROW'S OWN DATA: a Plus title Audible's
  # last scan no longer returns is a lapsed licence, and saying so is the
  # difference between "something went wrong" and "this book is gone".
  It 'worker: a Plus + absent-from-last-scan row names the lapsed licence'
    locked_libation LOCKED
    printf '%s\n' '{"provider":"libation","items":[{"id":"LOCKED","path":"Pierce Brown/Red Rising","title":"Red Rising","plus":true,"absent":true}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The stderr should include "acquire produced no files for Pierce Brown/Red Rising"
    The stderr should include "Audible Plus and absent from Audible's last scan"
    The stderr should include "licence has lapsed"
    # Warned before the attempt, never refused: AbsentFromLastScan can be
    # stale, and refusing on stale metadata would block a legitimate rip.
    The stderr should include "attempting anyway"
    The contents of file "$RIP_SANDBOX/libation.log" should include "--id LOCKED"
    The output should include 'rip: nothing settled to push for audiobooks (age gate 0s)'
  End

  # The sibling-credit trap. The reconcile step falls back to "the newest
  # book dir under this author", so in a batch of two books by ONE author it
  # would happily hand book two the folder book one just created — a failed
  # acquire re-keyed onto, and verified against, a sibling's files. Only a
  # directory that was not there before this item's acquire can be it.
  It 'worker: a failed acquire is not credited with a sibling book by the same author'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
case "$*" in
  *"--id LOCKED"*) echo "Done."; exit 0 ;;
esac
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart"},{"id":"LOCKED","path":"Brandon Sanderson/Wind and Truth","title":"Wind and Truth"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should not equal 0
    The stderr should include "acquire produced no files for Brandon Sanderson/Wind and Truth"
    The stderr should not include "Wind and Truth landed as"
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # …and the same batch, judged on ARTEFACTS rather than stderr (review
  # finding 3, 2026-08-24): the successful sibling must keep its own identity
  # in the sidecar, the failed book must not be pushed, and the meta index
  # must still key both books by their own paths — a re-key of the failed
  # item onto the sibling would hand the sibling the wrong identity on the
  # next push.
  It 'worker: a sibling-success/sibling-failure batch leaves the sidecar and the meta index correct'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
# argv is CAPTURED before the parse loop: the loop shifts it away, so a
# `case "$*"` after it would match nothing at all (and silently turn this
# fixture into "every acquire succeeds").
argv="$*"
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
case "$argv" in
  # The live shape of a lapsed licence: the destination is CREATED and then
  # nothing is written into it, and the CLI still exits 0.
  *"--id LOCKED"*) mkdir -p "$books/Brandon Sanderson/Wind and Truth"; exit 0 ;;
esac
mkdir -p "$books/Brandon Sanderson/Steelheart"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart/Steelheart.m4b"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"},{"id":"LOCKED","path":"Brandon Sanderson/Wind and Truth","title":"Wind and Truth"}]}' > "$RIP_SANDBOX/plan.json"
    # rip::ab_worker removes the meta index at the very END of the run (after
    # the push), so it cannot be read once `When run` returns. Snapshot it at
    # the moment the push reads it — the state the sidecar writer actually
    # sees — by wrapping rip::push_worker around a copy of itself.
    cat > "$RIP_SANDBOX/run.zsh" <<EOF
source "$RIPLIB"
functions -c rip::push_worker rip::_real_push_worker
rip::push_worker() {
  cp -- "\$RIP_STAGING_ROOT/.work/ab-meta.jsonl" "\$RIP_SANDBOX/ab-meta.snapshot" 2>/dev/null
  rip::_real_push_worker "\$@"
}
rip::ab_worker "\$RIP_SANDBOX/plan.json"
EOF
    When run zsh "$RIP_SANDBOX/run.zsh"
    The status should not equal 0
    The stderr should include "acquire produced no files for Brandon Sanderson/Wind and Truth"
    # THE NON-FACT: the empty composed dir the provider left behind is itself
    # "new since the snapshot", so the fallback used to name the book as
    # having landed as ITSELF and spend a jq+mv rewrite of the index on it.
    The stderr should not include "landed as"
    The contents of file "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json" should include "B00ECDZ08I"
    The contents of file "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart/.fleet-book.json" should include "The Reckoners, Book 1"
    The path "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Wind and Truth" should not be exist
    # both books still keyed by their OWN paths: no rewrite happened at all
    The contents of file "$RIP_SANDBOX/ab-meta.snapshot" should include '"path":"Brandon Sanderson/Steelheart"'
    The contents of file "$RIP_SANDBOX/ab-meta.snapshot" should include '"path":"Brandon Sanderson/Wind and Truth"'
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # THE MTIME-ORDER TRAP the same fix closes. A provider that writes its
  # files into a sanitized sibling and creates the composed dir AFTERWARDS
  # left the empty dir sorting first under (om), so a genuinely successful
  # acquire was reported as having produced nothing. Files decide, not mtime.
  It 'worker: a sanitized sibling holding the files beats an empty composed dir created after it'
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
books=""
while [ $# -gt 0 ]; do
  case "$1" in -o|--override) case "$2" in Books=*) books="${2#Books=}" ;; esac ;; esac
  shift
done
mkdir -p "$books/Brandon Sanderson/Steelheart (Unabridged)"
printf 'audio\n' > "$books/Brandon Sanderson/Steelheart (Unabridged)/Steelheart.m4b"
mkdir -p "$books/Brandon Sanderson/Steelheart"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
    printf '%s\n' '{"provider":"libation","items":[{"id":"B00ECDZ08I","path":"Brandon Sanderson/Steelheart","title":"Steelheart","subtitle":"The Reckoners, Book 1","ids":{"audible.asin":"B00ECDZ08I"},"provider":"libation","format":"m4b"}]}' > "$RIP_SANDBOX/plan.json"
    When run zsh -c "source $RIPLIB && rip::ab_worker $RIP_SANDBOX/plan.json"
    The status should equal 0
    The stderr should include "landed as Brandon Sanderson/Steelheart (Unabridged)"
    The stderr should not include "acquire produced no files"
    The contents of file "$RIP_SANDBOX/server/audiobooks/Brandon Sanderson/Steelheart (Unabridged)/.fleet-book.json" should include "B00ECDZ08I"
    The output should include 'rip: audiobooks verified on cantina — cleaning staging'
  End

  # --- ABS author enrichment (rip-abs-authors + the RIP_AB_REMOTE_HOPS
  # first entry, rip::_abs_match_authors) ------------------------------------
  #
  # Hermetic per the file header's own doctrine: fake curl behind
  # RIP_CURL_BIN, RIP_ABS_URL pointed at a sandbox value, never the real
  # cantina. AUDIOBOOKSHELF_API_KEY is explicitly unset before every use so
  # a value sitting in the real environment can never leak in.

  abs_get_calls() { grep -c '/api/libraries/lib-book/authors' "$RIP_SANDBOX/abscurl.log" 2>/dev/null || true; }

  # fake_abs_curl <authors_json> [items_json] — a fake ABS: /api/libraries
  # answers with a DECOY podcast library FIRST and the book library second
  # (so a test that hardcoded "the first library" instead of filtering on
  # mediaType would pick the wrong one and fail), /api/libraries/lib-book/authors
  # answers with <authors_json>, /api/libraries/lib-book/items answers with
  # <items_json> (default: one item, relPath "A/B", id "item-1" — the Task 7
  # brief's canned fixture), /api/authors/<id>/match always succeeds and
  # logs which id it was called for, and the item/author PATCH/DELETE
  # endpoints used by the Task 7 verbs just echo {} and log the request.
  fake_abs_curl() {
    export RIP_ABS_URL="http://cantina:13378"
    printf '%s' "$1" > "$RIP_SANDBOX/abs-authors.json"
    # The items fixture must NOT be written as a "${2:-<json>}" default: the
    # shell scans for the closing brace of the expansion through the JSON's
    # own braces and silently rewrites the literal (it emitted
    # ...,"relPath":"A/B"]}} — invalid JSON that jq rejects, so --find-item
    # found nothing). Pick the default with a plain test instead.
    abs_items_json="${2:-}"
    [ -n "$abs_items_json" ] || abs_items_json='{"results":[{"id":"item-1","relPath":"A/B"}]}'
    printf '%s' "$abs_items_json" > "$RIP_SANDBOX/abs-items.json"
    cat > "$RIP_SANDBOX/abscurl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/abscurl.log"
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a";; esac; done
case "\$url" in
  */api/libraries)
    echo '{"libraries":[{"id":"lib-pod","name":"Podcasts","mediaType":"podcast"},{"id":"lib-book","name":"Audiobooks","mediaType":"book"}]}' ;;
  */api/libraries/lib-book/authors)
    cat "$RIP_SANDBOX/abs-authors.json" ;;
  */api/libraries/lib-book/items)
    cat "$RIP_SANDBOX/abs-items.json" ;;
  */api/authors/*/match)
    id="\${url%/match}"; id="\${id##*/}"
    printf '{"updated":true,"author":{"id":"%s"}}' "\$id" ;;
  */api/items/*/media)
    echo '{}' ;;
  */api/items/*)
    echo '{}' ;;
  */api/authors/*)
    echo '{}' ;;
  *) echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$RIP_SANDBOX/abscurl"
    export RIP_CURL_BIN="$RIP_SANDBOX/abscurl"
  }

  It 'abs-authors: the book library is discovered by mediaType, not hardcoded'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/libraries/lib-book/authors"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/api/libraries/lib-pod/authors"
    The output should include 'rip-abs-authors: matched Brandon Sanderson'
  End

  It 'abs-authors: an author with both fields empty gets matched'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The output should include "matched Brandon Sanderson"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-1/match"
  End

  It 'abs-authors: an author with an existing image is skipped — no match call'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":"/var/lib/audiobookshelf/metadata/authors/auth-1.jpg"}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The output should include "skip (already populated)"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/match"
  End

  It 'abs-authors: an author with an existing bio is skipped — no match call'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[{"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":"Already has a bio.","imagePath":null}]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 0
    The output should include "skip (already populated)"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/match"
  End

  It 'abs-authors: --all matches every needing author and skips the rest'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[
      {"id":"auth-1","name":"Brandon Sanderson","asin":null,"description":null,"imagePath":null},
      {"id":"auth-2","name":"Andy Weir","asin":"B123","description":"has one","imagePath":"/x.jpg"}
    ]}'
    When run zsh -f "$ABS_BIN" --all
    The status should equal 0
    The output should include "matched Brandon Sanderson"
    The output should include "skip (already populated)"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-1/match"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/api/authors/auth-2/match"
  End

  It 'abs-authors: a missing API key exits 3 without any HTTP call'
    # zsh -f: skip ~/.zshenv, which re-injects the real AUDIOBOOKSHELF_API_KEY
    # from system-secrets — a bare unset is not hermetic once the key exists
    # in the real environment (same gotcha as rip-tmdb-search's TMDB_API_KEY
    # example).
    unset AUDIOBOOKSHELF_API_KEY
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson"
    The status should equal 3
    The stderr should include "AUDIOBOOKSHELF_API_KEY"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  It 'abs-authors: an author absent from ABS is polled then given up on without error'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    When run zsh -f "$ABS_BIN" "Nobody Home"
    The status should equal 0
    The output should include "gave up waiting"
    The result of function abs_get_calls should equal "2"
  End

  # AN UNRECOGNIZED FLAG IS AN ERROR, NOT AN AUTHOR NAME (live finding,
  # 2026-08-24). The dispatcher's `*)` arm was a bare `cmd_names "$@"`, so a
  # typo'd flag became a lookup for an author of that name and entered the
  # poll loop at its DEFAULTS — 12 tries x 5s, roughly a minute per argument
  # with no output at all. That is what made the operator's first command
  # look frozen. Note these examples deliberately do NOT throttle the poll
  # seams: the whole point is that no polling may happen. If the guard is
  # ever removed, they take ~60s and then fail.
  It 'abs-authors: an unrecognized flag is refused immediately, never polled as an author name'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-itme "A/B"
    The status should equal 2
    The stderr should include "unknown option: --find-itme"
    # Not a single HTTP call: the refusal happens before any lookup.
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  It 'abs-authors: a flag typo in second position is refused too'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" "Brandon Sanderson" --dry-run
    The status should equal 2
    The stderr should include "unknown option: --dry-run"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  # …and the refusal must not cost us author names that legitimately start
  # with a dash: `--` ends the options, exactly as it does everywhere else.
  It 'abs-authors: -- ends the options so a dash-leading author name is still reachable'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[{"id":"auth-7","name":"-dash Author","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" -- "-dash Author"
    The status should equal 0
    The output should include "matched -dash Author"
    # The marker itself is CONSUMED, never looked up as a name of its own:
    # the old dispatcher handed "--" straight to cmd_names, which polled for
    # an author called "--" and gave up on it.
    The output should not include "gave up waiting"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-7/match"
  End

  It 'abs-authors: -- with nothing after it is refused, not treated as a lookup'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --
    The status should equal 2
    The stderr should include "at least one author name required"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  # --- ABS primitives for retire + author repair (Task 7) -------------------
  #
  # Five new verbs on the same bin, consumed by a later task to retire a
  # book and repair duplicate author records: --find-item, --author-id,
  # --repoint-item, --delete-item, --delete-author. Same hermetic doctrine
  # as the enrichment examples above.
  #
  # Every example also throttles the ABS_AUTHOR_POLL_* seams (TRIES=2,
  # INTERVAL_S=0), exactly as the "gave up waiting" example above does. Not
  # for these examples' own sake — the flags below never reach cmd_names —
  # but as a regression guard: the dispatcher's `*)` arm falls through to
  # cmd_names "$@" for anything it does not recognize, so if a future change
  # ever un-wires one of these verbs from the case statement, the flag would
  # silently be treated as an author name and the example would hang for up
  # to a minute (12 tries * 5s) polling instead of failing fast.

  It 'abs: --find-item resolves an item by its relative path'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-item "A/B"
    The status should equal 0
    The output should equal "item-1"
  End

  It 'abs: --find-item exits 1 for a path the server does not hold'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-item "No/Such"
    The status should equal 1
  End

  It 'abs: --repoint-item PATCHes the item metadata with the given author'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --repoint-item item-1 auth-9 "J. R. R. Tolkien"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "PATCH"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/items/item-1/media"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "auth-9"
  End

  It 'abs: --delete-item and --delete-author issue DELETEs'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -c "zsh -f $ABS_BIN --delete-item item-1 && zsh -f $ABS_BIN --delete-author auth-9"
    The status should equal 0
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/items/item-1"
    The contents of file "$RIP_SANDBOX/abscurl.log" should include "/api/authors/auth-9"
  End

  It 'abs: --author-id resolves an author by exact name, reusing the authors listing'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[{"id":"auth-9","name":"J. R. R. Tolkien","asin":null,"description":null,"imagePath":null}]}'
    When run zsh -f "$ABS_BIN" --author-id "J. R. R. Tolkien"
    The status should equal 0
    The output should equal "auth-9"
    The contents of file "$RIP_SANDBOX/abscurl.log" should not include "/match"
  End

  It 'abs: --author-id exits 1 for a name the server does not hold'
    unset AUDIOBOOKSHELF_API_KEY; export AUDIOBOOKSHELF_API_KEY=test-key
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --author-id "Nobody"
    The status should equal 1
  End

  It 'abs: the new verbs exit 3 without an API key'
    unset AUDIOBOOKSHELF_API_KEY
    export RIP_ABS_AUTHOR_POLL_TRIES=2
    export RIP_ABS_AUTHOR_POLL_INTERVAL_S=0
    fake_abs_curl '{"authors":[]}'
    When run zsh -f "$ABS_BIN" --find-item "A/B"
    The status should equal 3
    The stderr should include "AUDIOBOOKSHELF_API_KEY"
    The path "$RIP_SANDBOX/abscurl.log" should not be exist
  End

  # --- rip::_abs_match_authors (the RIP_AB_REMOTE_HOPS entry itself) --------

  # fake_rip_abs_authors_bin — a stand-in for the deployed CLI, logging one
  # line per invocation with its full argv, so an example can assert both
  # HOW MANY TIMES the hop invoked it and WITH WHAT.
  fake_rip_abs_authors_bin() {
    cat > "$RIP_BIN_DIR/rip-abs-authors" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$RIP_SANDBOX/hop-calls.log"
${1:-exit 0}
EOF
    chmod +x "$RIP_BIN_DIR/rip-abs-authors"
  }

  hop_call_count() { wc -l < "$RIP_SANDBOX/hop-calls.log" 2>/dev/null | tr -d ' '; }

  It 'hop: derives and dedupes author names from relpaths — one call for two books by one author'
    fake_rip_abs_authors_bin
    When run zsh -c "source $RIPLIB && rip::_abs_match_authors '$RIP_SANDBOX/server' 'Brandon Sanderson/Steelheart/Steelheart.m4b' 'Brandon Sanderson/Wind and Truth/Wind and Truth.m4b' 'Other Author/Book/Book.m4b'"
    The status should equal 0
    The result of function hop_call_count should equal "1"
    The contents of file "$RIP_SANDBOX/hop-calls.log" should include "Brandon Sanderson"
    The contents of file "$RIP_SANDBOX/hop-calls.log" should include "Other Author"
  End

  It 'hop: no relpaths means no call at all'
    fake_rip_abs_authors_bin
    When run zsh -c "source $RIPLIB && rip::_abs_match_authors '$RIP_SANDBOX/server'"
    The status should equal 0
    The path "$RIP_SANDBOX/hop-calls.log" should not be exist
  End

  It 'hop: a failing/hanging ABS never fails the push — rip::_enrich_audiobooks_remote swallows it'
    fake_rip_abs_authors_bin "exit 1"
    printf '%s\n' "Brandon Sanderson/Steelheart/Steelheart.m4b" > "$RIP_SANDBOX/listfile"
    When run zsh -c "source $RIPLIB && rip::_enrich_audiobooks_remote $RIP_SANDBOX/listfile"
    The status should equal 0
    The stderr should include "remote enrichment hop failed"
    The result of function hop_call_count should equal "1"
  End

  # --- import (manual provider) ----------------------------------------------

  It 'import: stages a single file as <Author>/<Title>/<Title>.<ext>'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Ann Leckie' 'Ancillary Justice'"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should be exist
    The contents of file "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should equal "audio"
    The stderr should include 'rip: imported Ann Leckie/Ancillary Justice — the watcher will push it'
  End

  It 'import: stages a directory by copying its contents into the book dir'
    mkdir -p "$RIP_SANDBOX/incoming"
    printf 'audio\n' > "$RIP_SANDBOX/incoming/part1.m4b"
    printf 'art\n' > "$RIP_SANDBOX/incoming/cover.jpg"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'Ann Leckie' 'Ancillary Sword'"
    The status should equal 0
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Sword/part1.m4b" should be exist
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Sword/cover.jpg" should be exist
    The stderr should include 'rip: imported Ann Leckie/Ancillary Sword — the watcher will push it'
  End

  It 'import: records a manual-provider identity row in the meta index'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Ann Leckie' 'Ancillary Justice' && jq -c '{path,title,authors,provider}' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal '{"path":"Ann Leckie/Ancillary Justice","title":"Ancillary Justice","authors":["Ann Leckie"],"provider":"manual"}'
    The stderr should include 'rip: imported Ann Leckie/Ancillary Justice — the watcher will push it'
  End

  It 'import: rejects a traversing author or title'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' '..' 'X'"
    The status should equal 2
    The stderr should include "may not be . or .."
  End

  It 'import: refuses a missing source'
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/nope.m4b' 'A' 'B'"
    The status should equal 2
    The stderr should include "no such source"
  End

  It 'import: refuses to clobber a book already staged'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice"
    printf 'old\n' > "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b"
    printf 'new\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Ann Leckie' 'Ancillary Justice'"
    The status should equal 2
    The stderr should include "already staged"
    The contents of file "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Justice/Ancillary Justice.m4b" should equal "old"
  End

  It 'manual provider: capabilities says it cannot acquire, list is empty'
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-provider-manual" capabilities
    The status should equal 0
    The output should include '"name":"manual"'
    The output should include '"can_acquire":false'
  End

  It 'import: single-file basename is NFC-normalized (accented title)'
    nfc=$(printf 'Ant\xc3\xb4nio')
    nfd=$(printf 'Anto\xcc\x82nio')
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Test Author' '${nfd}'"
    The status should equal 0
    # The staged file must use NFC bytes in its name, even though the title arg was NFD
    The path "$RIP_STAGING_ROOT/audiobooks/Test Author/${nfc}/${nfc}.m4b" should be exist
    The stderr should include 'rip: imported Test Author/Antônio — the watcher will push it'
  End

  It 'import: a failed copy leaves nothing in the watched staging tree'
    mkdir -p "$RIP_SANDBOX/fake-cp-bin"
    cat > "$RIP_SANDBOX/fake-cp-bin/cp" <<'FAKECP'
#!/bin/sh
# Fake cp: fail on recursive copy (directory import case)
if [ "$1" = "-R" ]; then
  echo "I/O error: cannot copy" >&2
  exit 1
fi
# Otherwise, copy like normal cp
exec /bin/cp "$@"
FAKECP
    chmod +x "$RIP_SANDBOX/fake-cp-bin/cp"
    export PATH="$RIP_SANDBOX/fake-cp-bin:$PATH"
    mkdir -p "$RIP_SANDBOX/incoming"
    printf 'part1\n' > "$RIP_SANDBOX/incoming/part1.m4b"
    printf 'part2\n' > "$RIP_SANDBOX/incoming/part2.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'A' 'B'"
    The status should equal 1
    The stderr should include "could not copy"
    # Verify the destination directory does not exist (not even empty)
    The path "$RIP_STAGING_ROOT/audiobooks/A/B" should not be exist
  End

  It 'import: rejects a source file with no extension'
    printf 'audio\n' > "$RIP_SANDBOX/incoming"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'A' 'B'"
    The status should equal 2
    The stderr should include "no extension"
  End

  It 'import: records the actual format from a single-file import'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.mp3"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.mp3' 'Ann Leckie' 'Test' && jq -c '.format' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal '"mp3"'
    The stderr should include 'rip: imported Ann Leckie/Test — the watcher will push it'
  End

  # rip::ab_have's --have check hardcodes the lowercase "${rel:t}.m4b" —
  # an uppercase source extension taken verbatim would stage <Title>.M4B
  # and record format:"M4B", so the book could never match and would look
  # permanently absent from the server (2026-08-23 review finding).
  It 'import: lowercases an uppercase source extension in both the staged filename and the recorded format'
    printf 'audio\n' > "$RIP_SANDBOX/incoming.M4B"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.M4B' 'Ann Leckie' 'Ancillary Mercy' && jq -c '.format' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal '"m4b"'
    The path "$RIP_STAGING_ROOT/audiobooks/Ann Leckie/Ancillary Mercy/Ancillary Mercy.m4b" should be exist
    The stderr should include 'rip: imported Ann Leckie/Ancillary Mercy — the watcher will push it'
  End

  It 'import: directory with no audio files omits the format key'
    mkdir -p "$RIP_SANDBOX/incoming"
    printf 'text\n' > "$RIP_SANDBOX/incoming/readme.txt"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming' 'A' 'B' && jq -c 'has(\"format\")' \$(rip::_ab_meta_index_default)"
    The status should equal 0
    The output should equal 'false'
    The stderr should include 'rip: imported A/B — the watcher will push it'
  End

  It 'import: RIP_AB_STAGING override uses same-filesystem temp, leaves no debris'
    # Override staging to an entirely different tree outside the default root
    local custom_staging="$RIP_SANDBOX/custom-audiobooks"
    export RIP_AB_STAGING="$custom_staging"
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Test' 'Book'"
    The status should equal 0
    # Book lands in the override tree
    The path "$custom_staging/Test/Book/Book.m4b" should be exist
    # No debris in default staging root (verify Test/ dir never created there)
    The path "$RIP_STAGING_ROOT/audiobooks/Test" should not be exist
    # No temp debris left anywhere: count .rip-import.* dirs in parent
    The result of function find_temp_dirs should equal "0"
  End

  It 'import: dotfile-only destination (e.g. .DS_Store) is treated as empty'
    # Create destination containing only .DS_Store, which Finder creates
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Author/Title"
    printf 'macOS\n' > "$RIP_STAGING_ROOT/audiobooks/Author/Title/.DS_Store"
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Author' 'Title'"
    The status should equal 0
    # Book lands directly under Title/, not nested
    The path "$RIP_STAGING_ROOT/audiobooks/Author/Title/Title.m4b" should be exist
    # .DS_Store is gone (cleaned before rename)
    The path "$RIP_STAGING_ROOT/audiobooks/Author/Title/.DS_Store" should not be exist
    The stderr should include 'rip: imported Author/Title — the watcher will push it'
  End

  It 'import: refuses destination with real files, even if it also has dotfiles'
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Author/Title"
    printf 'old\n' > "$RIP_STAGING_ROOT/audiobooks/Author/Title/old.m4b"
    printf 'macOS\n' > "$RIP_STAGING_ROOT/audiobooks/Author/Title/.DS_Store"
    printf 'new\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Author' 'Title'"
    The status should equal 2
    The stderr should include "already staged"
    # Old file remains unchanged
    The contents of file "$RIP_STAGING_ROOT/audiobooks/Author/Title/old.m4b" should equal "old"
  End

  It 'import: destination containing a dot-directory refuses rather than nesting'
    # A dot-DIRECTORY (unlike a dotfile) survives both the clobber guard's
    # blind glob AND the pre-rename cleanup: `find -type f -delete` only
    # removes files, so the dot-directory remains, `rmdir` then fails
    # (directory not empty), and $dest survives to the mv. Without an
    # explicit invariant check, mv would nest the temp inside $dest instead
    # of publishing — the exact bug three review rounds already closed for
    # dotfiles, reopened here for dot-directories.
    mkdir -p "$RIP_STAGING_ROOT/audiobooks/Author/Title/.stray"
    printf 'audio\n' > "$RIP_SANDBOX/incoming.m4b"
    When run zsh -c "source $RIPLIB && rip::ab_import '$RIP_SANDBOX/incoming.m4b' 'Author' 'Title'"
    The status should equal 2
    The stderr should include "Author/Title"
    # Destination is left exactly as it was: the dot-directory survives,
    # nothing else was added (no nested import, no published book).
    The path "$RIP_STAGING_ROOT/audiobooks/Author/Title/.stray" should be exist
    The result of function dest_entry_count should equal "1"
    # No temp directory survives anywhere, nested or not.
    The result of function find_temp_dirs_anywhere should equal "0"
  End

  # mkbook_work — the same fixture, but carrying a `work` object, for the
  # uid-first grouping task 6 adds. <edition> "" means a bare anchor
  # (edition: null), the same shape rip::ab_backfill_work_uid leaves behind.
  mkbook_work() { # <author> <dir-title> <asin> <published> <bare-title> <uid> <edition>
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1/$2"
    jq -nc --arg t "$3" --arg p "$4" --arg ti "$5" --arg a "$1" --arg u "$6" --arg e "$7" \
      '{schema:1,kind:"audiobook",title:$ti,authors:[$a],ids:{"audible.asin":$t},
        published:(if $p=="" then null else $p end),
        work:{uid:$u, edition:(if $e=="" then null else $e end)}}' \
      > "$RIP_SANDBOX/server/audiobooks/$1/$2/.fleet-book.json"
  }

  # mkbook_work_array — a POISONED sidecar: `"work": []` instead of an
  # object. Reproduces the exact shape `_RIP_JQ_IDS_DEF` already documents
  # for `.ids`: a Lua-encoded empty table round-trips as `[]`, not `{}`, and
  # `.work.uid` RAISES on an array — the raise aborts the whole `-s` (slurp)
  # jq program under `2>/dev/null`, silently dropping every OTHER book from
  # the report while `--editions` still exits 0. This is the shape that
  # shipped books to the server with no `ids` identity at all under the
  # identical defect (review finding 2026-08-25); the fixture exists to
  # prove `--editions` does not repeat it for `work`.
  mkbook_work_array() { # <author> <dir-title> <asin> <published> <bare-title>
    mkdir -p "$RIP_SANDBOX/server/audiobooks/$1/$2"
    jq -nc --arg t "$3" --arg p "$4" --arg ti "$5" --arg a "$1" \
      '{schema:1,kind:"audiobook",title:$ti,authors:[$a],ids:{"audible.asin":$t},
        published:(if $p=="" then null else $p end), work:[]}' \
      > "$RIP_SANDBOX/server/audiobooks/$1/$2/.fleet-book.json"
  }

  It 'editions: two editions of one work group, newest marked'
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "Edgedancer"
    The output should include "B07626B9D2"
    The output should include "B0B5M28HZK"
    The output should include "newest"
  End

  It 'editions: parts of one issue sharing a publication date do NOT group (control edition still reported)'
    mkbook "Scientific American" "Scientific American, January 2001: Part 1" B002VE9P9A 2001-01-01T00:00:00 "Scientific American, January 2001"
    mkbook "Scientific American" "Scientific American, January 2001: Part 2" B0037FF924 2001-01-01T00:00:00 "Scientific American, January 2001"
    # Control book in the SAME fixture: a genuine two-date edition pair that
    # must still be reported. Without this, an example asserting only "the
    # output should not include X" would pass unchanged against a stub
    # `rip::ab_editions() { return 0 }` — no proof the grouping logic ran at
    # all (review finding 2026-08-24).
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Scientific American"
    The output should include "Edgedancer"
  End

  It 'editions: a cluster with any repeated date is suppressed ENTIRELY, not just the tied pair'
    # Regression for the shipped-jq defect (review finding 2026-08-24,
    # Critical): the old filter asked "does this cluster contain at least
    # one date difference anywhere" instead of "are ALL members' dates
    # distinct". Reproduced against the shipped program with exactly this
    # shape — two rows dated 2001-01-01 plus a third dated 2005-06-01 — and
    # all three printed side by side. A mixed cluster can never be safely
    # presented as an edition list: some of its rows are parts of one issue,
    # not alternative editions, and the report's downstream action is
    # deleting a "stale" copy the server holds the only copy of.
    mkbook "Scientific American" "Test Digest, Vol 3: Part 1" P1 2001-01-01T00:00:00 "Test Digest, Vol 3"
    mkbook "Scientific American" "Test Digest, Vol 3: Part 2" P2 2001-01-01T00:00:00 "Test Digest, Vol 3"
    mkbook "Scientific American" "Test Digest, Vol 3: Part 3" P3 2005-06-01T00:00:00 "Test Digest, Vol 3"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Test Digest"
    The output should include "Edgedancer"
  End

  It 'editions: two rows sharing a calendar date but not a time do NOT group (control edition still reported)'
    # Review finding 2, 2026-08-24: the cluster filter compared the RAW
    # `published` field while the line it prints one step later is
    # \(.published[0:10]) — and the panel's own edition mark slices the same
    # ten characters. `published` is Libation's DatePublished, a full
    # timestamp, so two parts of one issue that share a calendar date but
    # differ in the time component passed the all-distinct test and were
    # printed as an edition set: two IDENTICAL printed dates with one marked
    # `<- newest`, and a deletion as the only downstream action — while the
    # panel showed no mark at all for the same pair, so the two operator
    # surfaces disagreed. T07:00:00/T08:00:00 are midnight-Pacific
    # renderings, so a plain-date record mixed with a converted one on the
    # same day is the natural way this arrives.
    mkbook "Scientific American" "Test Digest, Vol 4: Part 1" Q1 2001-01-01T00:00:00 "Test Digest, Vol 4"
    mkbook "Scientific American" "Test Digest, Vol 4: Part 2" Q2 2001-01-01T07:00:00 "Test Digest, Vol 4"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Test Digest"
    The output should include "Edgedancer"
  End

  # The one-token hardening folded in with the date fix: the group key is
  # (first author, bare title), so two books with NO author at all would
  # cluster on ("", "<title>") and be offered up as editions of each other.
  It 'editions: two authorless books sharing a bare title never group'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/Unknown/One" "$RIP_SANDBOX/server/audiobooks/Unknown/Two"
    printf '%s' '{"schema":1,"title":"Anthology","authors":[],"ids":{"audible.asin":"Z1"},"published":"2001-01-01T00:00:00"}' \
      > "$RIP_SANDBOX/server/audiobooks/Unknown/One/.fleet-book.json"
    printf '%s' '{"schema":1,"title":"Anthology","authors":[],"ids":{"audible.asin":"Z2"},"published":"2009-01-01T00:00:00"}' \
      > "$RIP_SANDBOX/server/audiobooks/Unknown/Two/.fleet-book.json"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Anthology"
    The output should include "Edgedancer"
  End

  It 'editions: a dramatized adaptation is a different title and does NOT group (control edition still reported)'
    mkbook "Brandon Sanderson" "Tress of the Emerald Sea: A Cosmere Novel" B0B1 2023-01-10T00:00:00 "Tress of the Emerald Sea"
    mkbook "Brandon Sanderson" "Tress of the Emerald Sea (Dramatized Adaptation)" B0B2 2024-01-10T00:00:00 "Tress of the Emerald Sea (Dramatized Adaptation)"
    # Control book in the SAME fixture — see rationale above.
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "Tress"
    The output should include "Edgedancer"
  End

  It 'editions: a book with no published date is never grouped'
    mkbook "A" "T one" X1 "" T
    mkbook "A" "T two" X2 2020-01-01T00:00:00 T
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should not include "X1"
  End

  It 'editions: an empty library reports nothing and succeeds'
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should equal ""
  End

  # --- task 6: --editions groups by work.uid first (design S6) --------------
  #
  # These deliberately use DIFFERENT bare titles for the paired books (a real
  # edition, per design, changes the composed path) and a DISTINCT date pair
  # so the old author+title+distinct-date pipeline could not accidentally
  # group them itself — a passing assertion here can only be explained by the
  # new uid-first grouping actually running.

  # heading_order — the uid heading must precede the date heading (design S6:
  # "Print the uid section first"), not merely both be present somewhere.
  heading_order() {
    out="$(zsh -c "source $RIPLIB && rip::ab_editions")"
    uid_line="$(print -r -- "$out" | grep -n '^== confirmed editions' | head -1 | cut -d: -f1)"
    date_line="$(print -r -- "$out" | grep -n '^== possible duplicate editions' | head -1 | cut -d: -f1)"
    if [[ -n "$uid_line" && -n "$date_line" && "$uid_line" -lt "$date_line" ]]; then
      echo "uid-first"
    else
      echo "wrong-order"
    fi
  }

  It 'editions: two books sharing a work.uid group as one, with their edition labels'
    # Same published date on purpose: under the OLD (pre-task-6) pipeline
    # these would cluster on author+bare-title ("Foobar") and then be
    # SUPPRESSED ENTIRELY by the all-distinct-date filter, producing no
    # output for this pair at all — so this example is genuinely red against
    # the unmodified function, not just "unimplemented feature, empty by
    # default".
    mkbook_work "X Author" "Foobar" S1 2020-01-01T00:00:00 Foobar U-SILM ""
    mkbook_work "X Author" "Foobar (Full Cast)" S2 2020-01-01T00:00:00 Foobar U-SILM "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "U-SILM"
    The output should include "(none)"
    The output should include "Full Cast"
    The output should include "X Author/Foobar"
    The output should include "X Author/Foobar (Full Cast)"
  End

  It 'editions: the date-derived heuristic still reports its group, under its own heading'
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "== possible duplicate editions"
    The output should include "Edgedancer"
    The output should include "B07626B9D2"
    The output should include "B0B5M28HZK"
    The output should include "newest"
  End

  It 'editions: the two kinds are reported under separate headings'
    mkbook_work "X Author" "Foobar" S1 2020-01-01T00:00:00 Foobar U-SILM ""
    mkbook_work "X Author" "Foobar (Full Cast)" S2 2020-01-01T00:00:00 Foobar U-SILM "Full Cast"
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "== confirmed editions"
    The output should include "== possible duplicate editions"
    The result of function heading_order should equal "uid-first"
  End

  It 'editions: a work.uid group of ONE is not reported'
    # Paired control (U-SILM) proves the uid-grouping machinery ran at all;
    # the solo book (U-SOLO, its own asin S3) must not surface anywhere —
    # neither as a leaked singleton "work" group (the size-1 filter) nor
    # folded into the date section (it has no sibling by author+title
    # either).
    mkbook_work "X Author" "Foobar" S1 2020-01-01T00:00:00 Foobar U-SILM ""
    mkbook_work "X Author" "Foobar (Full Cast)" S2 2020-01-01T00:00:00 Foobar U-SILM "Full Cast"
    mkbook_work "Y Author" "SoloTitle" S3 2020-06-01T00:00:00 SoloTitle U-SOLO ""
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "U-SILM"
    The output should not include "U-SOLO"
    The output should not include "SoloTitle"
    The output should not include "S3"
  End

  It 'editions: a "work": [] sidecar does not drop other books from the report'
    # THE TRAP (carried from .ids, review finding 2026-08-25): a Lua-encoded
    # empty table round-trips as `[]`, not `{}`. `.work.uid` on an array
    # RAISES, and under `2>/dev/null` the raise would abort the whole slurped
    # jq program — silently dropping every OTHER book, uid-grouped or
    # date-grouped, while --editions still exits 0. The poisoned book sorts
    # alphabetically ahead of both control fixtures ("A Poisoned" < "Brandon"
    # < "X Author"), which is exactly the ordering that made the identical
    # `.ids` defect ship books with no identity at all — the raise happens on
    # the FIRST row a naive `.work.uid` would touch.
    mkbook_work_array "A Poisoned" "BadSidecar" S9 2020-01-01T00:00:00 BadSidecar
    mkbook_work "X Author" "Foobar" S1 2020-01-01T00:00:00 Foobar U-SILM ""
    mkbook_work "X Author" "Foobar (Full Cast)" S2 2020-01-01T00:00:00 Foobar U-SILM "Full Cast"
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "U-SILM"
    The output should include "Full Cast"
    The output should include "Edgedancer"
    The output should include "newest"
  End

  # --- AFTER THE MANDATORY BACKFILL (review finding, 2026-08-26) -----------
  #
  # The state every one of the examples above misses: `--backfill-work-uid
  # --apply` is REQUIRED (design S5) and mints a uid for EVERY stored book,
  # so the library the operator actually consults this report against has NO
  # uid-less books left in it. Every date example above uses `mkbook` (work
  # null) and every uid example uses `mkbook_work`; none mixed a
  # date-duplicate pair WITH uids, which is the only state the library is
  # ever in after that sweep — and in that state the partition on the mere
  # PRESENCE of a uid left `$rest` empty, so the date section never printed
  # again while each of those books was ALSO a singleton uid group and so
  # dropped from the uid section too. The pair vanished from BOTH sections:
  # rc 0, no output at all.
  #
  # These two fixtures are the same Edgedancer pair the date examples use,
  # anchored the way the sweep leaves them: each its own uid, `edition: null`.
  It 'editions: a date-derived duplicate pair still reports after the required backfill has anchored every book'
    mkbook_work "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer U-ANCH-1 ""
    mkbook_work "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer U-ANCH-2 ""
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "== possible duplicate editions"
    The output should include "B07626B9D2"
    The output should include "B0B5M28HZK"
    The output should include "newest"
    # ...and neither singleton uid leaks into the confirmed section on its way
    # through: falling through to the heuristic is not the same as being a
    # work of one.
    The output should not include "== confirmed editions"
    The output should not include "U-ANCH-1"
  End

  # The other half of the same partition, and the reason it cannot simply be
  # "every book falls through": a book that IS in a reported uid group must
  # NOT also be date-grouped. These two share one uid AND would satisfy the
  # heuristic on their own (same first author, same bare title, distinct
  # dates), so a fix that sent every anchored book through the fallback would
  # report this pair twice, under both headings.
  It 'editions: a reported uid group is not ALSO reported by the date heuristic'
    mkbook_work "X Author" "Foobar" S1 2020-01-01T00:00:00 Foobar U-SILM ""
    mkbook_work "X Author" "Foobar (Full Cast)" S2 2021-01-01T00:00:00 Foobar U-SILM "Full Cast"
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 0
    The output should include "== confirmed editions"
    The output should include "U-SILM"
    The output should not include "== possible duplicate editions"
    The output should not include "newest"
  End

  # server_sidecars_ssh <dir> — install a fake ssh implementing the exact
  # enumeration rip::_server_sidecars sends over the wire (mindepth/maxdepth
  # 3, .fleet-book.json only), counting its own invocations into
  # ssh.count. Ignores the actual remote command argv, like the
  # --server-library fake above — it re-does the equivalent walk locally
  # against the sandbox server dir, which is all these examples need.
  server_sidecars_ssh() {
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
echo 1 >> "$RIP_SANDBOX/ssh.count"
cd "$RIP_SANDBOX/server/audiobooks" || exit 2
find . -mindepth 3 -maxdepth 3 -name .fleet-book.json 2>/dev/null | while read -r f; do
  d=${f#./}; d=${d%/.fleet-book.json}
  printf "%s\t" "$d"; tr -d "\n" < "$f"; printf "\n"
done
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
  }

  # rip::_stored_sha_index — the dedupe key acquire consults for a locally
  # imported book: "<sha256>\t<Author>/<Title>" for every stored sidecar
  # carrying ids["local.sha256"]. Derived from the same rip::_server_sidecars
  # enumeration the editions report above already uses, not a second ssh —
  # pinned here with a real (fake) ssh rather than the plain-local-dir
  # remote base the two examples used before, so ssh_calls() means something.
  It 'stored-sha index: maps a stored local.sha256 to its book path'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"fleet.uid":"u1","local.sha256":"deadbeef"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    server_sidecars_ssh
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should equal 0
    The output should include "deadbeef	A/B"
    The result of function ssh_calls should equal "1"
  End

  It 'stored-sha index: a sidecar with no local.sha256 contributes nothing'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"audible.asin":"X1"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    server_sidecars_ssh
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should equal 0
    The output should equal ""
    The result of function ssh_calls should equal "1"
  End

  # Finding 2 (review, 2026-08-25): rip::_stored_sha_index used to swallow
  # rip::_server_sidecars' own failure propagation behind `2>/dev/null`,
  # returning rc 0 with empty output — indistinguishable from "asked the
  # server, it has no locally-hashed books" for a DEDUPE check, which reads
  # an empty index as "not a duplicate": an unreachable server would
  # silently DISABLE dedupe rather than refuse. Mirrors the editions
  # unreachable-server example above exactly, including the message.
  It 'stored-sha index: an unreachable server returns non-zero and says so, never a silently empty index'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::_stored_sha_index"
    The status should not equal 0
    The output should equal ""
    The stderr should include "could not read the stored sidecars"
  End

  # Finding D (review, 2026-08-25): the example above pins only that a
  # failure is reported — not the load-bearing OTHER half, that
  # _RIP_STORED_SHA_FETCHED stays unset on that failure so a LATER call in
  # the same process retries instead of being stuck with the poisoned
  # empty cache forever. A future `_RIP_STORED_SHA_FETCHED=1` creeping back
  # above the `return $rc` would break exactly this while the example above
  # stayed green. A sentinel file makes the fake ssh unreachable for the
  # FIRST call and reachable for the second, both within one process (one
  # `zsh -c`, so the cache globals genuinely persist between the two calls).
  It 'stored-sha index: an unreachable server does not poison the cache — a later call in the same process recovers'
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s\n' '{"schema":1,"kind":"audiobook","title":"B","authors":["A"],"ids":{"fleet.uid":"u1","local.sha256":"deadbeef"}}' \
      | jq . > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    touch "$RIP_SANDBOX/ssh-sentinel"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
if [ -e "$RIP_SANDBOX/ssh-sentinel" ]; then
  exit 255
fi
cd "$RIP_SANDBOX/server/audiobooks" || exit 2
find . -mindepth 3 -maxdepth 3 -name .fleet-book.json 2>/dev/null | while read -r f; do
  d=${f#./}; d=${d%/.fleet-book.json}
  printf "%s\t" "$d"; tr -d "\n" < "$f"; printf "\n"
done
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    export RIP_REMOTE_BASE="media@cantina:/srv/media"
    When run zsh -c "source $RIPLIB
      rip::_stored_sha_index >/dev/null 2>/dev/null
      first_rc=\$?
      rm -f '$RIP_SANDBOX/ssh-sentinel'
      rip::_stored_sha_index
      print -ru2 -- \"first_rc=\$first_rc\""
    The status should equal 0
    The output should include "deadbeef	A/B"
    The stderr should include "first_rc=2"
  End

  # THE REPORT AN OPERATOR READS BEFORE DECIDING WHAT TO DELETE (review
  # finding 4, 2026-08-24). rip::_server_sidecars used to discard the ssh
  # status on both branches, so an unreachable server produced rc 0 and
  # empty output — byte-identical to "your library has no duplicate
  # editions". --canonicalize-authors already returns 2 in the same
  # situation and --backfill-published at least names the possibility.
  It 'editions: an unreachable server returns 2 and says so, never a silent clean bill of health'
    mkbook "Brandon Sanderson" "Edgedancer: From the Stormlight Archive" B07626B9D2 2017-10-03T07:00:00 Edgedancer
    mkbook "Brandon Sanderson" "Edgedancer: Stormlight Archive" B0B5M28HZK 2022-10-04T07:00:00 Edgedancer
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_editions"
    The status should equal 2
    The output should equal ""
    The stderr should include "could not read the stored sidecars"
  End

  # …and the failure must reach the panel's feed too: the Hammerspoon
  # library panel keeps SERVER_EDITIONS_KNOWN false only when the task
  # exits non-zero, which is what preserves its tri-state discipline
  # (an empty list with KNOWN true would assert "no other editions exist").
  It 'CLI: --server-editions propagates an unreachable server as a non-zero exit'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --server-editions
    The status should not equal 0
    The output should equal ""
    The stderr should include "could not read the stored sidecars"
  End

  # --server-editions — the panel's edition-mark feed. Thin: one jq filter
  # over rip::_server_sidecars (already covered above), shaped to
  # {author, title, published, path}. Exercised through the CLI dispatcher,
  # not the raw function, so this also proves the verb is actually wired in.
  It 'CLI: --server-editions emits published rows as {author,title,published,path}'
    mkbook "A" "B" X1 2020-01-01T00:00:00 T
    mkbook "A" "C" X2 "" T2
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --server-editions
    The status should equal 0
    The output should include '"author":"A"'
    The output should include '"title":"T"'
    The output should include '"published":"2020-01-01T00:00:00"'
    The output should include '"path":"A/B"'
    The output should not include "X2"
    The output should not include '"path":"A/C"'
  End

  # --- --at-risk: which of my stored books can I never get again? -----------
  #
  # The runbook's backup doctrine — "audiobooks are not backed up; Audible is
  # the permanent copy" — is true for a book you BOUGHT and false for one you
  # BORROWED. A stored Audible Plus title whose licence has already lapsed
  # cannot be liberated again by anyone, so cantina's copy is the only copy in
  # existence. This verb is the durable answer to "which ones are those".

  # at_risk_library <json> — point the fake LibationCli's export at a
  # hand-written library so an example can state exactly which titles are
  # Plus and which have lapsed.
  at_risk_library() {
    cat > "$RIP_SANDBOX/atrisk-library.json"
    cat > "$RIP_SANDBOX/LibationCli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RIP_SANDBOX/libation.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -p|--path) out="$2" ;; esac
  shift
done
cp "$RIP_SANDBOX/atrisk-library.json" "$out"
exit 0
EOF
    chmod +x "$RIP_SANDBOX/LibationCli"
  }

  It 'CLI: --at-risk lists the stored books whose Audible Plus licence has lapsed'
    mkbook "Martha Wells" "Network Effect" B08X1 "" "Network Effect"
    mkbook "Martha Wells" "All Systems Red" B08X2 "" "All Systems Red"
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X1","Title":"Network Effect","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X2","Title":"All Systems Red","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false},
 {"AudibleProductId":"B08X4","Title":"Never Ripped","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"NotLiberated","IsAudiblePlus":true,"AbsentFromLastScan":true}
]
JSON
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --at-risk
    The status should equal 0
    The output should include "Martha Wells/Network Effect"
    The output should include "Martha Wells/All Systems Red"
    # owned outright — not at risk
    The output should not include "Wind and Truth"
    # lapsed but never ripped: already gone, and NOT a stored book, so it has
    # no place on a list of what the server alone is keeping alive
    The output should not include "Never Ripped"
    # the header has to say what the list MEANS, not just print paths
    The output should include "2 stored book(s) can NEVER be re-acquired"
    The output should include "the only copy that exists"
  End

  It 'CLI: --at-risk says so plainly when nothing is at risk'
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false}
]
JSON
    When run zsh "$SHELLSPEC_PROJECT_ROOT/home/dot_local/bin/executable_rip-audiobook" --at-risk
    The status should equal 0
    The output should include "nothing at risk"
  End

  # A borrowed title still IN the catalog is not at risk yet — it is the one
  # the panel nags about ripping. It must not be listed here, or the verb's
  # answer stops meaning "irreplaceable".
  It 'at-risk: a Plus title still in the catalog is not listed'
    mkbook "Martha Wells" "Fugitive Telemetry" B08X2 "" "Fugitive Telemetry"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X2","Title":"Fugitive Telemetry","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":false}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "nothing at risk"
    The output should not include "Fugitive Telemetry"
  End

  # FALSE REASSURANCE IS THE FAILURE THIS VERB MUST NEVER PRODUCE. Read
  # through `< <(...)` an unreachable server is byte-identical to an empty
  # library, and "nothing at risk" for a server we never reached is exactly
  # the wrong answer.
  It 'at-risk: an unreachable server is an error, never "nothing at risk"'
    export RIP_REMOTE_BASE="fakehost:/srv/media"
    cat > "$RIP_SANDBOX/ssh" <<'EOF'
#!/bin/sh
exit 255
EOF
    chmod +x "$RIP_SANDBOX/ssh"
    export RIP_SSH_BIN="$RIP_SANDBOX/ssh"
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 2
    The output should not include "nothing at risk"
    The stderr should include "could not read the stored sidecars"
  End

  # …and the same for a provider that answers with nothing: an empty library
  # cannot be told apart from "Libation did not answer".
  It 'at-risk: an empty provider library is an error, never "nothing at risk"'
    mkbook "Martha Wells" "Network Effect" B08X1 "" "Network Effect"
    at_risk_library <<'JSON'
[]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 2
    The output should not include "nothing at risk"
    The stderr should include "refusing to report an at-risk set"
  End

  # THE JOIN MUST NOT BE EXACT-PATH-ONLY (review finding 1, 2026-08-24).
  # Libation files a book under "Shawn Speakman - editor" where the server
  # holds "Shawn Speakman" — a divergence rip::ab_repair_sidecars already
  # carries a title-tier fallback for, and rip::_canonical_author measured
  # live. With the exact join alone the stored book matched NOTHING and was
  # folded into "not at risk": a lapsed Plus title, the only copy in
  # existence, reported as safe.
  It 'at-risk: a lapsed book whose server author spelling differs from Libation is still found'
    # No ASIN on this sidecar — the ASIN tier only fires when there is one to
    # try, so this exercises the title-tier FALLBACK the ASIN tier now sits
    # in front of, exactly as before.
    mkbook "Shawn Speakman" "Unfettered III" "" "" "Unfettered III"
    mkbook "Martha Wells" "Network Effect" B08X1 "" "Network Effect"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X9","Title":"Unfettered III","Subtitle":"","AuthorNames":"Shawn Speakman - editor",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true},
 {"AudibleProductId":"B08X1","Title":"Network Effect","Subtitle":"","AuthorNames":"Martha Wells",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "2 stored book(s) can NEVER be re-acquired"
    The output should include "Shawn Speakman/Unfettered III"
    The output should include "Martha Wells/Network Effect"
    The output should not include "nothing at risk"
    # matched by title, so nothing is left unaccounted for
    The output should not include "Plus status is unknown"
  End

  # THE ASIN TIER IS THE HEADLINE FIX (2026-08-24): it must resolve a stored
  # book even when NEITHER the composed path NOR the bare title matches — the
  # exact scenario the exact-path and title tiers both fail on. Author AND
  # title both diverge from Libation's own spelling here, on purpose, so
  # nothing but the ASIN can carry this match. Pre-fix (no ASIN tier at all)
  # this book matches no row by any means and lands in the leftover bucket
  # instead of "can NEVER be re-acquired" — this example fails pre-fix.
  It 'at-risk: the ASIN join finds a lapsed book despite BOTH author and title spelling differing from Libation'
    mkbook "Shawn Speakman" "Unfettered III Anthology" B08X9 "" "Unfettered III Anthology"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X9","Title":"Unfettered III","Subtitle":"","AuthorNames":"Shawn Speakman - editor",
  "BookStatus":"Liberated","IsAudiblePlus":true,"AbsentFromLastScan":true}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "1 stored book(s) can NEVER be re-acquired"
    The output should include "Shawn Speakman/Unfettered III Anthology"
    The output should not include "does not seem to be an Audible book"
    The output should not include "could not be established"
  End

  # AND THE REAL ANOMALY: a sidecar that CARRIES an Audible ASIN, but no
  # provider row lists it any more. This is not "unknown" the way a plain
  # unmatched book is — it is evidence Libation dropped a book that claims an
  # Audible identity, and the report must say exactly that shape and nothing
  # more (a lapsed Plus licence, a returned purchase and an account change
  # all look identical from here — this subsystem does not guess which).
  It 'at-risk: a stored book carrying an ASIN Libation no longer lists gets its own line, not silence'
    mkbook "Some Author" "Ripped Elsewhere" B0FAKEGONE "" "Ripped Elsewhere"
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "1 stored book(s) carries an Audible ASIN that libation no longer lists"
    The output should include "its Plus status could not be established"
    The output should include "Some Author/Ripped Elsewhere"
    # THE FALSE REASSURANCE THIS VERB EXISTS TO PREVENT: with a book it could
    # not speak for in hand, it must not say every book on cantina is
    # owned-or-in-catalogue.
    The output should not include "every book on cantina"
    # the book it DID resolve is still reported as not at risk
    The output should include "nothing at risk among the books that matched"
    The output should not include "can NEVER be re-acquired"
    The output should not include "does not seem to be an Audible book"
  End

  # A MANUAL IMPORT — no `audible.asin` in the sidecar at all — is not an
  # Audible book to begin with, so calling its Plus status "unknown" is
  # alarmist and wrong: this check simply does not apply to it. It must be
  # named plainly and kept out of the "not established" anomaly bucket
  # above, and its presence alone must not force the "matched a row" hedge
  # either — every Audible-provider title on cantina WAS resolved.
  It 'at-risk: a manual import with no ASIN is reported as not an Audible book, not as an anomaly'
    mkbook "Ernest Cline" "Ready Player One" "" "" "Ready Player One"
    mkbook "Brandon Sanderson" "Wind and Truth" B08X3 "" "Wind and Truth"
    at_risk_library <<'JSON'
[
 {"AudibleProductId":"B08X3","Title":"Wind and Truth","Subtitle":"","AuthorNames":"Brandon Sanderson",
  "BookStatus":"Liberated","IsAudiblePlus":false,"AbsentFromLastScan":false}
]
JSON
    When run zsh -c "source $RIPLIB && rip::ab_at_risk"
    The status should equal 0
    The output should include "1 stored book(s) does not seem to be an Audible book:"
    The output should include "Ernest Cline/Ready Player One"
    The output should not include "could not be established"
    The output should not include "can NEVER be re-acquired"
    # not the hedge — no Audible-identified book was left unresolved, only a
    # book that was never in this check's scope
    The output should not include "matched a libation row"
    The output should not include "every book on cantina"
    The output should include "nothing at risk among cantina's Audible titles"
  End

  # rip::ab_backfill_published — sweep the 248 sidecars already on the server
  # (0 of which carry `published`, measured 2026-08-24) so edition detection
  # has something to group on. Each example redirects RIP_LIBEXEC_DIR into
  # the sandbox FIRST: setup() points it at the real tracked libexec dir, and
  # writing a fake provider without redirecting would overwrite the repo's
  # own source file.
  #
  # book_published() — the stored sidecar's `published` field for the fixed
  # A/B fixture every example below writes via mkbook. shellspec's "result"
  # modifier only accepts a defined shell function as its subject (see
  # dest_entry_count/find_temp_dirs above), not an arbitrary command string.
  book_published() {
    jq -r '.published' "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
  }

  It 'backfill: dry-run names the books it would fill and writes nothing'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "A/B"
    The output should include "2019-05-07"
    The output should include "re-run with --apply"
    The result of function book_published should equal "null"
  End

  It 'backfill: --apply fills the missing date and leaves every other field alone'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply && jq -c '[.published,.title,.authors[0],.ids[\"audible.asin\"],.kind]' $RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    The status should equal 0
    The output should include '["2019-05-07T07:00:00","B","A","X1","audiobook"]'
  End

  It 'backfill: a sidecar that already has a date is never rewritten'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 2001-01-01T00:00:00 B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply && jq -r '.published' $RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    The status should equal 0
    # "nothing to backfill" is now unconditional (review finding 2026-08-24,
    # Risk 1): an already-dated book is the to_fill==0 case in BOTH modes, so
    # stdout is that message followed by the unchanged date, not the date
    # alone. Asserting the message is itself a stub-defeating check: a
    # `rip::ab_backfill_published() { return 0 }` stub prints nothing, so
    # only the pre-existing mkbook date would appear and this line would fail.
    The output should include "nothing to backfill"
    The output should include "2001-01-01T00:00:00"
  End

  It 'backfill: a stored book the provider does not offer is reported unmatched, not touched'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" XORPHAN "" B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    # rc 1 and a summary line naming the count, not a bare "nothing to
    # backfill" with rc 0 (review finding 3B, 2026-08-24) — see the
    # every-candidate-failed example below.
    The status should equal 1
    The output should include "still undated"
    The stderr should include "no provider row"
    # …and the sidecar itself is untouched: still undated, nothing rewritten.
    The contents of file "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json" should include '"published":null'
  End

  # Review finding 3B, 2026-08-24: the seen==0 branch tells "the enumerator
  # produced nothing" apart from "the library is satisfied", but NOT from
  # "every candidate was seen and every one failed to match a provider row".
  # Reproduced with a provider whose export fails (exit 3 — LibationCli
  # missing, unauthorized, or mid-update): the warnings scroll past, then
  # `rip: nothing to backfill` lands on stdout with rc 0. The operator reads
  # the last line, concludes the one-shot sweep is done, sees --editions
  # report nothing, and concludes the library has no duplicates.
  It 'backfill: every candidate failing to match is reported as such, not as "nothing to backfill"'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkbook "A" "C" X2 "" C
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
echo "LibationCli not found" >&2
exit 3
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "2 book(s) still undated"
    The output should not include "nothing to backfill"
    The stderr should include "no provider row"
  End

  # The same distinction for the OTHER continue: a sidecar with no ASIN at
  # all cannot be backfilled either, and must not be summarised as a clean
  # sweep.
  It 'backfill: a candidate with no ASIN is counted in the undated summary too'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s' '{"schema":1,"title":"B","authors":["A"],"ids":{},"published":null}' \
      > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "1 book(s) still undated"
    The stderr should include "no ASIN"
  End

  It 'backfill: nothing to fill reports so and succeeds'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 2001-01-01T00:00:00 B
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "nothing to backfill"
    # Distinguishes this branch (sidecars WERE seen, all already dated) from
    # the "enumerator produced zero lines" branch below — review round 2,
    # 2026-08-24: without this negative assertion a real bug that always
    # emitted the "no sidecars found" wording, even when sidecars exist,
    # would pass this example unnoticed.
    The output should not include "cantina reachable"
  End

  It 'backfill: an enumerator that returns nothing is distinguished from a satisfied library'
    # Review finding 2026-08-24, round 2: "rip: nothing to backfill" alone
    # does not tell an operator whether every stored sidecar genuinely
    # already has a date, or whether rip::_server_sidecars produced ZERO
    # lines because the ssh to the server failed (that ssh runs under
    # 2>/dev/null, so an unreachable server and a satisfied library both
    # yield rc 0 and an empty work list). This is a one-shot sweep over 248
    # books — a false "nothing to backfill" here reads as "the sweep is
    # done" and a real gap propagates silently into --editions reporting no
    # duplicates either. An empty library legitimately produces zero lines
    # too (no mkbook call below — nothing staged in $RIP_SANDBOX/server at
    # all), so the wording only names the possibility, it does not assert
    # server-unreachability as fact.
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    The output should include "no sidecars found on the server"
    The output should include "cantina reachable"
  End

  It 'backfill: a malformed stored sidecar is warned about, not silently dropped'
    # Regression for review finding 2026-08-24 (Risk 2): rip::_server_sidecars
    # runs a per-line `jq -c ... 2>/dev/null`, which used to silently DROP any
    # line that fails to parse — the book never entered the backfill loop, so
    # it wasn't "skipped and warned", it was invisible. Same enumerator feeds
    # rip::ab_editions, so a corrupt sidecar would vanish from every report
    # the operator uses to reason about the library.
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkdir -p "$RIP_SANDBOX/server/audiobooks/C/D"
    printf '%s' '{"schema":1, "title": "D", BROKEN' > "$RIP_SANDBOX/server/audiobooks/C/D/.fleet-book.json"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 0
    # The healthy book is still processed correctly — a `return 0` stub
    # would print none of this.
    The output should include "A/B"
    The output should include "2019-05-07"
    # The malformed sidecar is warned about, not silently absent.
    The stderr should include "malformed"
    The stderr should include "C/D"
  End

  # Final-fix review, 2026-08-24 (R1): a PARTIAL sweep — some sidecars filled,
  # some left undated — used to report only "backfilled N of N sidecar(s)"
  # with rc 0, which reads as a complete sweep even though other candidates
  # were skipped. This is a one-shot run over 248 real books; a partial
  # success masquerading as a clean bill of health is exactly the shape that
  # let a real gap propagate silently into --editions finding no duplicates.
  It 'backfill: a partial --apply sweep reports the still-undated remainder and fails'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkbook "A" "C" X2 "" C
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published --apply"
    # A/B matches the provider row and gets filled; A/C has no matching row
    # and stays undated — the summary must say so, not just the tally for
    # the books it touched, and the exit code must tell a wrapper too.
    The status should equal 1
    The output should include "backfilled 1 of 1 sidecar(s)"
    The output should include "1 book(s) still undated"
    The stderr should include "no provider row for A/C"
  End

  # Same partial-sweep gap in dry-run mode: "would fill: A/B … (1 book(s);
  # re-run with --apply)" read alone claims the WHOLE sweep is one book, when
  # a second candidate (A/C) was seen and could not be matched.
  It 'backfill: a partial dry run reports the still-undated remainder and fails'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkbook "A" "B" X1 "" B
    mkbook "A" "C" X2 "" C
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
[ "$1" = list ] && printf '%s\n' '{"id":"X1","path":"A/B","title":"B","published":"2019-05-07T07:00:00"}'
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "would fill: A/B"
    The output should include "re-run with --apply"
    The output should include "1 book(s) still undated"
    The stderr should include "no provider row for A/C"
    # Nothing was written — dry run.
    The result of function book_published should equal "null"
  End

  # Final-fix review, 2026-08-24 (R2): both "no ASIN" and "no provider row"
  # increment the same counter, and the summary always blamed LibationCli
  # ("no provider row matched; is LibationCli available?") even when the
  # real cause is a sidecar with no ASIN at all — precisely the fingerprint
  # of an orphaned-identity book the operator most needs to recognise during
  # live validation. The summary must name the ASIN cause instead.
  It 'backfill: a no-ASIN sidecar is named in the summary, not blamed on LibationCli'
    export RIP_LIBEXEC_DIR="$RIP_SANDBOX/libexec"
    mkdir -p "$RIP_LIBEXEC_DIR"
    mkdir -p "$RIP_SANDBOX/server/audiobooks/A/B"
    printf '%s' '{"schema":1,"title":"B","authors":["A"],"ids":{},"published":null}' \
      > "$RIP_SANDBOX/server/audiobooks/A/B/.fleet-book.json"
    cat > "$RIP_LIBEXEC_DIR/rip-provider-libation" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$RIP_LIBEXEC_DIR/rip-provider-libation"
    When run zsh -c "source $RIPLIB && rip::ab_backfill_published"
    The status should equal 1
    The output should include "1 book(s) still undated"
    The output should include "no ASIN"
    The output should not include "LibationCli"
    The stderr should include "no ASIN"
  End
End
