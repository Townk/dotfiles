# rip-bd-menu — the Blu-ray session pre-fill harvester: structure from the
# scan rows (twin / play-all / parts), names from the disc's BD-J menu assets
# (button slugs, handler order, OCR'd sprite text). Fixture-only: a fake disc
# tree under the sandbox and a fake tesseract. The rows are the first UHD
# (PROJECT_HAIL_MARY, 2026-09-06) plus its three sub-2-minute scenes.
Describe 'rip-bd-menu'
  HELPER="$SHELLSPEC_PROJECT_ROOT/home/dot_local/libexec/executable_rip-bd-menu"

  setup() {
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
    # fake tesseract: prints tesseract-shaped text (blocks separated by blank
    # lines, a wrapped label inside one block) per sprite sheet
    cat > "$S/tesseract" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_TESS_LOG:-/dev/null}"
[ -n "${FAKE_TESS_FAIL:-}" ] && exit 1
case "$1" in
  *eng_composite_1.png) printf 'SCENE\nSELECTIONS\n\nDISC\nMENU\n\nAUDIO\n\nSPECIAL\nFEATURES\n\nPLAY\n' ;;
  *eng_composite_2.png) printf 'COMMENTARY BY\nDIRECTORS PHIL LORD\nAND CHRISTOPHER MILLER\n\nOFF\n\nI THINK I'"'"'M HANDLING THINGS\nPRETTY AWESOME\n\nFRANÇAIS\n\nESPAÑOL\n\nSUBTITLES\n\nENGLISH (FOR THE DEAF AND HARD OF HEARING)\n\nYOU SLEEP, I WATCH\n\nDAY 1 FOOD PASTE\n\nDELETED SCENES\n\nPLAY ALL\n\nEARTH'"'"'S FAVORITE ERIDIAN\n\nHOW TO PUT ON A SPACESUIT\n' ;;
  *eng_composite_3.png) printf 'HOW TO PUT ON A SPACESUIT\n\nMAYBE WE'"'"'RE COUSINS\n\nPLAY ALL\n\nENGLISH\n\nENGLISH DESCRIPTIVE AUDIO\n\nNEDERLANDS\n' ;;
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
  cleanup() { rm -rf "$S"; }
  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_helper() { python3 "$HELPER" "$S/disc" < "$S/rows.jsonl" > "$S/out.json"; jq -r "$1" "$S/out.json"; }

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
    The output should equal "I Think I'm Handling Things Pretty Awesome | You Sleep, I Watch | Day 1 Food Paste | Earth's Favorite Eridian | How to Put On a Spacesuit | Maybe We're Cousins | I Think I'm Handling Things | Pretty Awesome"
  End

  It 'only OCRs the requested language and the common sheets'
    export FAKE_TESS_LOG="$S/tess.log"; : > "$FAKE_TESS_LOG"
    When call run_helper '.candidates | length'
    The output should equal "8"
    The contents of file "$FAKE_TESS_LOG" should include "eng_composite_2.png"
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
    When run python3 "$HELPER" "$S/disc"
    The status should equal 2
    The stderr should include "rows"
  End
End
