# rip-bd-menu — the Blu-ray session pre-fill harvester: structure from the
# scan rows (twin / play-all / parts), names from the disc's BD-J menu assets
# (handler order in the jar, labels OCR'd from each button's own crop of the
# resources_<lang>.xml sprite atlas). Fixture-only: a fake disc tree under the
# sandbox and fake magick/tesseract binaries. Two fixtures:
#   legacy — a resources XML with NO regions, exercising the whole-sheet OCR
#            fallback and the structure rules;
#   atlas  — the REAL PROJECT_HAIL_MARY material (21 scan rows at minlength
#            30, the disc's own atlas regions, its seven handler names and
#            the readings tesseract actually produced from the crops).
Describe 'rip-bd-menu'
  HELPER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-bd-menu"

  cleanup() { rm -rf "$S"; }
  AfterEach 'cleanup'

  run_helper() { python3 "$HELPER" "$S/disc" < "$S/rows.jsonl" > "$S/out.json"; jq -r "$1" "$S/out.json"; }

  Describe 'legacy disc — a resources XML with no atlas regions'
    legacy_fixture() {
      S=$(mktemp -d)
      D="$S/disc/BDMV/JAR"
      mkdir -p "$D/00001"
      cat > "$D/00001/resources_eng.xml" <<'EOF'
<resources>
  <image name="common_composite_1"/>
  <image name="en_button_audio_a_bt2020_hdr"/>
  <image name="en_button_chaphighlight_a_bt2020_hdr"/>
  <image name="en_button_chTxt01_a_bt2020_hdr"/>
  <image name="en_button_sceneselections_a_bt2020_hdr"/>
  <image name="en_button_specialfeatures_a_bt2020_hdr"/>
  <image name="en_button_DeletedScenes_a_bt2020_hdr"/>
  <image name="en_button_CommentaryBy_a_bt2020_hdr"/>
  <image name="en_button_PlayAll_a_bt2020_hdr"/>
  <image name="en_button_FoodPaste_a_bt2020_hdr"/>
  <image name="en_button_FoodPaste_n_bt2020_hdr"/>
  <image name="en_button_HandlingThings_a_bt2020_hdr"/>
  <image name="en_button_PutOnSpacesuit_a_bt2020_hdr"/>
  <image name="en_button_YouSleep_a_bt2020_hdr"/>
  <image name="en_button_WereCousins_a_bt2020_hdr"/>
  <image name="en_button_EarthsEridian_a_bt2020_hdr"/>
  <image name="fr_button_YouSleep_a_bt2020_hdr"/>
</resources>
EOF
      printf '%s\n' 'SF_02_EarthsEridian_onKeyPressed' 'SF_01_DS_05_WereCousins_onKeyPressed' \
        'SF_01_DS_01_FoodPaste_onKeyPressed' 'SF_01_DS_03_PutOnSpacesuit_onKeyPressed' \
        'SF_01_DS_02_HandlingThings_onKeyPressed' 'SF_01_DS_04_YouSleep_onKeyPressed' \
        'extrasmenu_Deletedscenes_onUnload' > "$S/handlers.txt"
      (cd "$S" && zip -q -j "$D/00000.jar" handlers.txt)
      : > "$D/00001/eng_composite_1.png"; : > "$D/00001/eng_composite_2.png"; : > "$D/00001/eng_composite_3.png"
      : > "$D/00001/fra_composite_1.png"
      : > "$D/00001/common_composite_1.png"
      # fake tesseract: prints tesseract-shaped text (blocks separated by blank
      # lines, a wrapped label inside one block) per sprite sheet
      cat > "$S/tesseract" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_TESS_LOG:-/dev/null}"
[ -n "${FAKE_TESS_FAIL:-}" ] && exit 1
case "$1" in
  *eng_composite_1.png) printf 'SCENE\nSELECTIONS\n\nDISC\nMENU\n\nAUDIO\n\nSPECIAL\nFEATURES\n\nPLAY\n' ;;
  *eng_composite_2.png) printf 'COMMENTARY BY\nDIRECTORS PHIL LORD\nAND CHRISTOPHER MILLER\n\nOFF\n\nI THINK I'"'"'M HANDLING THINGS\nPRETTY AWESOME\n\nFRANÇAIS\n\nESPAÑOL\n\nSUBTITLES\n\nENGLISH (FOR THE DEAF AND HARD OF HEARING)\n\nYOU SLEEP, I WATCH\n\nDAY 1 FOOD PASTE\n\nDELETED SCENES\n\nPLAY ALL\n\nEARTH'"'"'S FAVORITE ERIDIAN\n\nHOW TO PUT ON A SPACESUIT\n' ;;
  *eng_composite_3.png) printf 'HOW TO PUT ON A SPACESUIT\n\nMAYBE WE'"'"'RE COUSINS\n\nTHE MAKING OF\n\nPLAY ALL\n\nENGLISH\n\nENGLISH DESCRIPTIVE AUDIO\n\nNEDERLANDS\n' ;;
  *) printf '' ;;
esac
exit 0
EOF
      chmod +x "$S/tesseract"; export RIP_TESSERACT_BIN="$S/tesseract"
      cat > "$S/rows.jsonl" <<'EOF'
{"no":0,"seconds":9391,"source":"01199.mpls","segments":"589"}
{"no":1,"seconds":125,"source":"00149.mpls","segments":"174,175"}
{"no":2,"seconds":125,"source":"01213.mpls","segments":"600,601"}
{"no":3,"seconds":598,"source":"00720.mpls","segments":"643,644,645,646,647"}
{"no":4,"seconds":9391,"source":"00589.m2ts","segments":"589"}
{"no":5,"seconds":473,"source":"00719.mpls","segments":"648"}
{"no":6,"seconds":140,"source":"00715.mpls","segments":"644"}
{"no":7,"seconds":140,"source":"00717.mpls","segments":"646"}
{"no":8,"seconds":99,"source":"00714.mpls","segments":"643"}
{"no":9,"seconds":109,"source":"00716.mpls","segments":"645"}
{"no":10,"seconds":107,"source":"00718.mpls","segments":"647"}
EOF
    }
    BeforeEach 'legacy_fixture'

    It 'skips the feature twin (same segments, raw m2ts)'
      When call run_helper '.suggest["4"] | "\(.role) \(.why)"'
      The output should equal "skip twin"
    End

    It 'skips the play-all and names its parts in menu order'
      When call run_helper '[.suggest["3"].why, .suggest["8"].name, .suggest["6"].name, .suggest["9"].name, .suggest["7"].name, .suggest["10"].name] | join(" | ")'
      The output should equal "playall | Day 1 Food Paste | I Think I'm Handling Things Pretty Awesome | How to Put On a Spacesuit | You Sleep, I Watch | Maybe We're Cousins"
    End

    It 'names the standalone featurette from the SF slug and marks menu-mapped rows as extras'
      When call run_helper '.suggest["5"] | "\(.role) \(.why) \(.name)"'
      The output should equal "extra menu Earth's Favorite Eridian"
    End

    It 'defaults unmapped titles to skip once at least one name mapped'
      When call run_helper '[.suggest["1"].why, .suggest["2"].role] | join(" ")'
      The output should equal "unmapped skip"
    End

    It 'never suggests anything for the feature'
      When call run_helper '.suggest | has("0")'
      The output should equal "false"
    End

    It 'lists candidates in OCR order, blocks joined, UI words dropped, title-cased'
      When call run_helper '.candidates | join(" | ")'
      The output should equal "I Think I'm Handling Things Pretty Awesome | You Sleep, I Watch | Day 1 Food Paste | Earth's Favorite Eridian | How to Put On a Spacesuit | Maybe We're Cousins | The Making Of | I Think I'm Handling Things | Pretty Awesome"
    End

    # A label that ENDS on a small word ends on it deliberately: "The Making
    # of" reads as a truncation, so title_case lowercases small words in the
    # middle only (final review, 2026-09-06).
    It 'never lowercases the last word: THE MAKING OF -> The Making Of'
      When call run_helper '.candidates | index("The Making Of") != null'
      The output should equal "true"
    End

    It 'only OCRs the requested language and the common sheets'
      export FAKE_TESS_LOG="$S/tess.log"; : > "$FAKE_TESS_LOG"
      When call run_helper '.candidates | length'
      The output should equal "9"
      The contents of file "$FAKE_TESS_LOG" should include "eng_composite_2.png"
      The contents of file "$FAKE_TESS_LOG" should include "common_composite_1.png"
      The contents of file "$FAKE_TESS_LOG" should not include "fra_composite"
    End

    It 'falls back to slug-rendered names when tesseract fails'
      export FAKE_TESS_FAIL=1
      When call run_helper '[.suggest["10"].name, .suggest["10"].why, (.candidates|length)] | map(tostring) | join(" ")'
      The output should equal "Were Cousins slug 0"
      The stderr should include "tesseract"
    End

    It 'with no JAR directory emits structure only: twin, play-all, parts unnamed, nothing else'
      rm -rf "$D"
      When call run_helper '[.suggest["4"].why, .suggest["3"].why, .suggest["8"].role, .suggest["8"].name, .suggest["8"].why, (.suggest|has("1")), (.suggest|has("5"))] | map(tostring) | join(" ")'
      The output should equal "twin playall extra  part false false"
      The stderr should include "no BDMV/JAR"
    End

    It 'emits an empty suggest map for a disc with no twin, no play-all and no names'
      rm -rf "$D"
      printf '%s\n' '{"no":0,"seconds":6000,"source":"00001.mpls","segments":"1"}' '{"no":1,"seconds":300,"source":"00002.mpls","segments":"2"}' > "$S/rows.jsonl"
      When call run_helper '[(.suggest|length), (.candidates|length)] | map(tostring) | join(" ")'
      The output should equal "0 0"
      The stderr should include "no BDMV/JAR"
    End

    It 'exits 2 on unreadable rows'
      printf 'not json\n' > "$S/rows.jsonl"
      When run sh -c "python3 '$HELPER' '$S/disc' < '$S/rows.jsonl'"
      The status should equal 2
      The stderr should include "not JSON"
    End

    It 'exits 2 on empty stdin'
      When run sh -c "python3 '$HELPER' '$S/disc' < /dev/null"
      The status should equal 2
      The stderr should include "nothing on stdin"
    End

    It 'exits 2 on a non-numeric row field'
      printf '%s\n' '{"no":"x","seconds":10,"source":"00001.mpls","segments":"1"}' > "$S/rows.jsonl"
      When run sh -c "python3 '$HELPER' '$S/disc' < '$S/rows.jsonl'"
      The status should equal 2
      The stderr should include "not a number"
    End

    It 'harvests OCR independent of slugs: no resources xml, no jar, sprite sheets present'
      rm -f "$D/00001/resources_eng.xml" "$D/00000.jar"
      When call run_helper '[(.candidates|length), (.suggest|[.[].why]|unique|join(","))] | join(" ")'
      The output should equal "9 part,playall,twin"
    End

    It 'has no twin, no play-all and no feature suggestion when nothing shares segments'
      rm -rf "$D"
      printf '%s\n' '{"no":0,"seconds":9000,"source":"00589.m2ts","segments":"589"}' \
        '{"no":1,"seconds":300,"source":"00149.mpls","segments":"149"}' \
        '{"no":2,"seconds":250,"source":"00150.mpls","segments":"150"}' > "$S/rows.jsonl"
      When call run_helper '.suggest | length'
      The output should equal "0"
      The stderr should include "no BDMV/JAR"
    End
  End

  # The live pass: PROJECT_HAIL_MARY scanned at minlength 30 (21 rows), the
  # disc's own atlas regions, its seven handler names, and the strings
  # tesseract actually returned from the ImageMagick-prepared crops.
  Describe 'atlas disc — PROJECT_HAIL_MARY, the real live-pass material'
    atlas_fixture() {
      S=$(mktemp -d)
      D="$S/disc/BDMV/JAR"
      mkdir -p "$D/00001"
      cat > "$D/00001/resources_eng.xml" <<'EOF'
<resources>
  <composite name="common_composite_1">
  </composite>
  <composite name="loader">
  </composite>
  <composite name="eng_composite_1">
    <image name="en_button_audio_n_bt2020_hdr" x="1699" y="477" width="187" height="68" hasTransparency="1" />
    <image name="en_button_play_n_bt2020_hdr" x="1689" y="864" width="156" height="68" hasTransparency="1" />
    <image name="en_button_setaudio03_n_bt2020_hdr" x="1373" y="333" width="469" height="70" hasTransparency="1" />
  </composite>
  <composite name="eng_composite_2">
    <image name="en_button_commentaryby_n_bt2020_hdr" x="589" y="172" width="589" height="139" hasTransparency="1" />
    <image name="en_button_day1_n_bt2020_hdr" x="0" y="826" width="408" height="65" hasTransparency="1" />
    <image name="en_button_deletedscenes_n_bt2020_hdr" x="1221" y="826" width="405" height="65" hasTransparency="1" />
    <image name="en_button_earthsfavorite_n_bt2020_hdr" x="997" y="891" width="592" height="65" hasTransparency="1" />
    <image name="en_button_howto_n_bt2020_hdr" x="1228" y="956" width="636" height="65" hasTransparency="1" />
    <image name="en_button_playall_n_bt2020_hdr" x="1589" y="891" width="228" height="65" hasTransparency="1" />
    <image name="en_button_thinkim_n_bt2020_hdr" x="0" y="450" width="632" height="102" hasTransparency="1" />
    <image name="en_button_yousleep_n_bt2020_hdr" x="440" y="759" width="440" height="67" hasTransparency="1" />
  </composite>
  <composite name="eng_composite_3">
    <image name="en_button_maybewere_n_bt2020_hdr" x="1150" y="0" width="514" height="65" hasTransparency="1" />
  </composite>
</resources>
EOF
      # the handler names the live jar actually carries; SF_01_DS_00_PlayAll
      # is a real handler and must NOT count as a member of the DS group
      printf '%s\n' 'SF_01_DS_00_PlayAll_onKeyPressed' 'SF_01_DS_01_FoodPaste_onKeyPressed' \
        'SF_01_DS_02_HandlingThings_onKeyPressed' 'SF_01_DS_03_PutOnSpacesuit_onKeyPressed' \
        'SF_01_DS_04_YouSleep_onKeyPressed' 'SF_01_DS_05_WereCousins_onKeyPressed' \
        'SF_02_EarthsEridian_onKeyPressed' > "$S/handlers.txt"
      (cd "$S" && zip -q -j "$D/00000.jar" handlers.txt)
      for sheet in common_composite_1 loader eng_composite_1 eng_composite_2 eng_composite_3; do
        printf 'PNG\n' > "$D/00001/$sheet.png"
      done
      # fake magick: log argv, then copy the SOURCE (first argument) onto the
      # OUTPUT (last argument) so the crop the helper then OCRs exists
      cat > "$S/magick" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_MAGICK_LOG:-/dev/null}"
src=$1
for a in "$@"; do out=$a; done
cp "$src" "$out"
EOF
      chmod +x "$S/magick"; export RIP_MAGICK_BIN="$S/magick"
      # fake tesseract: the readings the real one produced from these crops,
      # keyed on the crop's filename (<slug>.png); anything else is silent.
      # The stoplisted buttons (playall, deletedscenes, commentaryby, audio,
      # play, setaudio03) deliberately have NO branch: they must never be
      # cropped, so a reading for them could only ever be dead code.
      # `makingof` is used by the >= 60 s floor example below.
      cat > "$S/tesseract" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_TESS_LOG:-/dev/null}"
case "$1" in
  *day1.png) printf 'DAY 1FOOD PASTE\n' ;;
  *thinkim.png) printf 'I THINK TM HANDLING THINGS PRETTY AWESOME\n' ;;
  *howto.png) printf 'HOW TO PUT ON A SPACESUIT\n' ;;
  *yousleep.png) printf 'YOU SLEEP, | WATCH\n' ;;
  *maybewere.png) printf 'MAYBE WE'"'"'RE COUSINS\n' ;;
  *earthsfavorite.png) printf 'EARTH'"'"'S FAVORITE ERIDIAN\n' ;;
  *makingof.png) printf 'THE MAKING OF\n' ;;
  *) printf '' ;;
esac
exit 0
EOF
      chmod +x "$S/tesseract"; export RIP_TESSERACT_BIN="$S/tesseract"
      cat > "$S/rows.jsonl" <<'EOF'
{"no":0,"seconds":51,"source":"00011.mpls","segments":"10"}
{"no":1,"seconds":9391,"source":"01199.mpls","segments":"589"}
{"no":2,"seconds":125,"source":"00149.mpls","segments":"174,175"}
{"no":3,"seconds":30,"source":"01072.mpls","segments":"340,561,562"}
{"no":4,"seconds":40,"source":"01197.mpls","segments":"582,583,584,586"}
{"no":5,"seconds":30,"source":"01200.mpls","segments":"564,565,580"}
{"no":6,"seconds":40,"source":"01202.mpls","segments":"594,595,596,597"}
{"no":7,"seconds":125,"source":"01213.mpls","segments":"600,601"}
{"no":8,"seconds":598,"source":"00720.mpls","segments":"643,644,645,646,647"}
{"no":9,"seconds":62,"source":"00174.m2ts","segments":"174"}
{"no":10,"seconds":62,"source":"00175.m2ts","segments":"175"}
{"no":11,"seconds":51,"source":"00010.m2ts","segments":"10"}
{"no":12,"seconds":9391,"source":"00589.m2ts","segments":"589"}
{"no":13,"seconds":62,"source":"00600.m2ts","segments":"600"}
{"no":14,"seconds":62,"source":"00601.m2ts","segments":"601"}
{"no":15,"seconds":473,"source":"00648.m2ts","segments":"648"}
{"no":16,"seconds":99,"source":"00643.m2ts","segments":"643"}
{"no":17,"seconds":140,"source":"00644.m2ts","segments":"644"}
{"no":18,"seconds":109,"source":"00645.m2ts","segments":"645"}
{"no":19,"seconds":140,"source":"00646.m2ts","segments":"646"}
{"no":20,"seconds":107,"source":"00647.m2ts","segments":"647"}
EOF
    }
    BeforeEach 'atlas_fixture'

    It 'names the five deleted scenes 16-20 in menu order'
      When call run_helper '[.suggest["16"].name, .suggest["17"].name, .suggest["18"].name, .suggest["19"].name, .suggest["20"].name] | join(" | ")'
      The output should equal "Day 1 Food Paste | I Think Tm Handling Things Pretty Awesome | How to Put On a Spacesuit | You Sleep, I Watch | Maybe We're Cousins"
    End

    It 'marks the five scenes as menu-mapped extras'
      When call run_helper '[.suggest["16"], .suggest["20"]] | map("\(.role) \(.why)") | join(" ")'
      The output should equal "extra menu extra menu"
    End

    It 'names the standalone featurette 15 from the SF_02 handler'
      When call run_helper '.suggest["15"] | "\(.role) \(.why) \(.name)"'
      The output should equal "extra menu Earth's Favorite Eridian"
    End

    It 'skips the deleted-scenes play-all 8'
      When call run_helper '.suggest["8"] | "\(.role) \(.why)"'
      The output should equal "skip playall"
    End

    It 'skips the feature twin 12 and the menu-stub twin 11'
      When call run_helper '[.suggest["12"].why, .suggest["11"].why] | join(" ")'
      The output should equal "twin twin"
    End

    # 00149 and 01213 are two-segment TRAILER playlists, structurally
    # identical to a deleted-scenes play-all: only the part count tells them
    # apart from the five-scene group (live-pass amendment).
    It 'gives the five-name DS group the five-part play-all, not a two-part trailer'
      When call run_helper '[.suggest["8"].why, .suggest["2"].why, .suggest["7"].why] | join(" ")'
      The output should equal "playall unmapped unmapped"
    End

    It 'skips the trailer playlists 2 and 7 as unmapped'
      When call run_helper '[.suggest["2"], .suggest["7"]] | map("\(.role) \(.why)") | join(" ")'
      The output should equal "skip unmapped skip unmapped"
    End

    It 'skips the trailers own segments 9, 10, 13, 14 as segments'
      When call run_helper '[.suggest["9"], .suggest["10"], .suggest["13"], .suggest["14"]] | map("\(.role) \(.why)") | join(" ")'
      The output should equal "skip segment skip segment skip segment skip segment"
    End

    It 'skips the menu stubs 0, 3, 4, 5, 6 as unmapped'
      When call run_helper '[.suggest["0"], .suggest["3"], .suggest["4"], .suggest["5"], .suggest["6"]] | map("\(.role) \(.why)") | unique | join(" ")'
      The output should equal "skip unmapped"
    End

    It 'never suggests anything for the feature 1'
      When call run_helper '.suggest | has("1")'
      The output should equal "false"
    End

    It 'offers the six menu labels as candidates, in XML order'
      When call run_helper '.candidates | join(" | ")'
      The output should equal "Day 1 Food Paste | Earth's Favorite Eridian | How to Put On a Spacesuit | I Think Tm Handling Things Pretty Awesome | You Sleep, I Watch | Maybe We're Cousins"
    End

    It 'never offers a UI button as a candidate'
      When call run_helper '[.candidates[] | select(. == "Deleted Scenes" or . == "Play All" or . == "Audio")] | length'
      The output should equal "0"
    End

    It 'crops only the non-stoplisted buttons, from their _n region'
      export FAKE_MAGICK_LOG="$S/magick.log"; : > "$FAKE_MAGICK_LOG"
      When call run_helper '.candidates | length'
      The output should equal "6"
      # the ORDERED fragment: the sheet is the input, the crop geometry is
      # applied to it, and +repage follows so the crop's origin is dropped
      The contents of file "$FAKE_MAGICK_LOG" should include "eng_composite_2.png -crop 408x65+0+826 +repage"
      The contents of file "$FAKE_MAGICK_LOG" should not include "playall.png"
      The contents of file "$FAKE_MAGICK_LOG" should not include "setaudio03.png"
    End

    # The first deployed atlas harvest wedged the UDF mount reading the same
    # sheet a dozen times straight off the optical drive (live-pass
    # amendment, spec 2026-09-06): the helper now copies BDMV/JAR to scratch
    # once and crops only from the copy.
    It 'reads the disc'\''s JAR directory once: every magick crop reads the scratch copy, never the mount'
      export FAKE_MAGICK_LOG="$S/magick.log"; : > "$FAKE_MAGICK_LOG"
      When call run_helper '.candidates | length'
      The output should equal "6"
      The contents of file "$FAKE_MAGICK_LOG" should not include "$S/disc/BDMV/JAR"
      The contents of file "$FAKE_MAGICK_LOG" should include "/JAR/"
    End

    # `|` is tesseract reading the I of "I WATCH"; "1FOOD" is the digit of
    # "DAY 1" glued to the word after it.
    It 'cleans a standalone | to I and splits a digit glued to a word'
      When call run_helper '[.suggest["16"].name, .suggest["19"].name] | join(" | ")'
      The output should equal "Day 1 Food Paste | You Sleep, I Watch"
    End

    It 'falls back to whole-sheet OCR when ImageMagick is missing'
      export RIP_MAGICK_BIN="/nonexistent/magick"
      export FAKE_TESS_LOG="$S/tess.log"; : > "$FAKE_TESS_LOG"
      When call run_helper '.candidates | length'
      The output should equal "0"
      The contents of file "$FAKE_TESS_LOG" should include "_composite_"
      The contents of file "$FAKE_TESS_LOG" should not include "day1.png"
      The stderr should include "magick"
    End

    It 'still names the scenes from their slugs when ImageMagick is missing'
      export RIP_MAGICK_BIN="/nonexistent/magick"
      When call run_helper '[.suggest["16"].name, .suggest["16"].why] | join(" ")'
      The output should equal "Food Paste slug"
      The stderr should include "magick"
    End

    # The conservatism rule outranks the play-all sweep (review fix,
    # 2026-09-06): a disc whose handlers carry no DS numbers claims no
    # play-all, and sweeping unconditionally would bury every deleted scene
    # under Skip with nothing named. Nothing mapped -> structure-only.
    only_sf_handler() {
      printf '%s\n' 'SF_02_EarthsEridian_onKeyPressed' > "$S/handlers.txt"
      rm -f "$D/00000.jar"; (cd "$S" && zip -q -j "$D/00000.jar" handlers.txt)
      # drop the only >= 60 s standalone below the floor so nothing maps
      sed 's/"no":15,"seconds":473/"no":15,"seconds":50/' "$S/rows.jsonl" > "$S/r2"
      mv "$S/r2" "$S/rows.jsonl"
    }

    It 'keeps the play-all and its parts intact when no name mapped at all'
      only_sf_handler
      When call run_helper '[.suggest["8"].why, (.suggest["16"]|"\(.role) \(.why)"), (.suggest["20"]|"\(.role) \(.why)")] | join(" | ")'
      The output should equal "playall | extra part | extra part"
    End

    It 'never marks a segment skip when no name mapped at all'
      only_sf_handler
      When call run_helper '[.suggest[].why] | unique | join(",")'
      The output should equal "part,playall,twin"
    End

    # The >= 60 s floor, with a SECOND standalone name in play: only row 15
    # (473 s) is eligible, so the second name has nowhere to go rather than
    # landing on the 51 s menu stub at 00011.
    second_sf_handler() {
      printf '%s\n' 'SF_01_DS_00_PlayAll_onKeyPressed' 'SF_01_DS_01_FoodPaste_onKeyPressed' \
        'SF_01_DS_02_HandlingThings_onKeyPressed' 'SF_01_DS_03_PutOnSpacesuit_onKeyPressed' \
        'SF_01_DS_04_YouSleep_onKeyPressed' 'SF_01_DS_05_WereCousins_onKeyPressed' \
        'SF_02_EarthsEridian_onKeyPressed' 'SF_03_MakingOf_onKeyPressed' > "$S/handlers.txt"
      rm -f "$D/00000.jar"; (cd "$S" && zip -q -j "$D/00000.jar" handlers.txt)
      grep -v '</resources>' "$D/00001/resources_eng.xml" > "$S/x.xml"
      {
        printf '  <composite name="eng_composite_4">\n'
        printf '    <image name="en_button_makingof_n_bt2020_hdr" x="10" y="20" width="300" height="65" hasTransparency="1" />\n'
        printf '  </composite>\n</resources>\n'
      } >> "$S/x.xml"
      mv "$S/x.xml" "$D/00001/resources_eng.xml"
      printf 'PNG\n' > "$D/00001/eng_composite_4.png"
    }

    # Without the floor the second name lands on a menu stub: 01072 (30 s) is
    # nearest the scenes' range, 00011 (51 s) next. Both must stay unmapped
    # and the label must appear on NO row — only in the dropdown.
    It 'offers the second label but never puts it on a sub-60 s title'
      second_sf_handler
      When call run_helper '[(.candidates|index("The Making Of") != null), .suggest["0"].why, .suggest["3"].why, ([.suggest[].name]|index("The Making Of") == null)] | map(tostring) | join(" ")'
      The output should equal "true unmapped unmapped true"
    End

    It 'still gives the one eligible standalone the first SF name'
      second_sf_handler
      When call run_helper '.suggest["15"].name'
      The output should equal "Earth's Favorite Eridian"
    End

    # No play-all has five parts, so the five-name DS group takes the CLOSEST
    # one and its names zip onto however many parts that play-all has.
    It 'falls back to the closest part count when no play-all has exactly k'
      printf '%s\n' '{"no":0,"seconds":9000,"source":"01199.mpls","segments":"589"}' \
        '{"no":1,"seconds":250,"source":"00149.mpls","segments":"174,175"}' \
        '{"no":2,"seconds":120,"source":"00174.m2ts","segments":"174"}' \
        '{"no":3,"seconds":130,"source":"00175.m2ts","segments":"175"}' > "$S/rows.jsonl"
      When call run_helper '[.suggest["1"].why, .suggest["2"].name, .suggest["3"].name] | join(" | ")'
      The output should equal "playall | Day 1 Food Paste | I Think Tm Handling Things Pretty Awesome"
    End
  End
End
