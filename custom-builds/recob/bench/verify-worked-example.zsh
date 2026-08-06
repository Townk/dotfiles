#!/usr/bin/env zsh
# Verify the §4.4 worked example byte-for-byte against the §4.3 field grammar.
setopt nomultibyte
enc_field() {
  local name=$1 value=$2
  local -i nl=$#name vl=$#value
  local -i b1=$(( (vl>>24)&255 )) b2=$(( (vl>>16)&255 )) b3=$(( (vl>>8)&255 )) b4=$(( vl&255 ))
  REPLY="${(#)nl}${name}${(#)b1}${(#)b2}${(#)b3}${(#)b4}${value}"
}
body=""
enc_field op        "clip.set"          ; body+=$REPLY
enc_field text      $'hi\n\0'           ; body+=$REPLY
enc_field regtype   "l"                 ; body+=$REPLY
enc_field origin_host "boxA"            ; body+=$REPLY
print -r -- "body length = $#body (0x$(printf '%02x' $#body))"
local -i n=$#body
local -i c1=$(( (n>>24)&255 )) c2=$(( (n>>16)&255 )) c3=$(( (n>>8)&255 )) c4=$(( n&255 ))
frame="Q${(#)c1}${(#)c2}${(#)c3}${(#)c4}${body}"
print -r -- "frame length = $#frame"
print -rn -- "$frame" | od -An -tx1 -v | tr -s ' '
