#!/usr/bin/env zsh
# prompt-common.zsh — interactive prompt helpers shared by the tools that
# collect input (system-secrets, system-onboard, commit-*). SOURCED, never
# executed. Masked entry uses `read -rk` and zsh slices. Pulls in the common.zsh
# base for C_*, log_warn, die, and have_tty.
#
# Raw read / read -s (no gum dependency in bootstrap-adjacent tools; predictable
# over SSH for secret entry). All read from /dev/tty so prompts work even when
# stdin is a pipe. A future gum backend can drop in behind these names.

# Source the base relative to THIS file.
_prompt_common_self="${(%):-%x}"
source "$(dirname "$_prompt_common_self")/common.zsh"
unset _prompt_common_self

# prompt::required <varname> <prompt> — loop until non-empty; sets the named var.
prompt::required() {
  local __var="$1" __prompt="$2" __val=""
  while :; do
    printf '%s%s%s ' "$C_BWH" "$__prompt" "$C_RES" >/dev/tty
    IFS= read -r __val </dev/tty || die "input aborted"
    [[ -n "$__val" ]] && break
    log_warn "a value is required"
  done
  printf -v "$__var" '%s' "$__val"
}

# prompt::default <varname> <prompt> <default> — empty input keeps the default.
prompt::default() {
  local __var="$1" __prompt="$2" __default="$3" __val=""
  printf '%s%s%s [%s] ' "$C_BWH" "$__prompt" "$C_RES" "$__default" >/dev/tty
  IFS= read -r __val </dev/tty || die "input aborted"
  [[ -n "$__val" ]] || __val="$__default"
  printf -v "$__var" '%s' "$__val"
}

# prompt::secret <varname> <prompt> — masked entry: echoes a '*' per keystroke
# instead of the usual blind no-echo read, so there's visual feedback while
# typing/pasting a secret. Supports Backspace and ^U (clear). Reads raw, one
# char at a time, with the tty put in -echo -icanon; the terminal is restored
# on normal completion and on ^C, and on a terminating signal (TERM/HUP/QUIT)
# or process exit so a kill/timeout at the prompt can't leave echo off. Falls
# back to a plain no-echo read when there is no controlling terminal
# (pipelines/tests). Loops until non-empty.
prompt::secret() {
  local __var="$1" __prompt="$2" __val=""
  # local_traps scopes the tty-restore traps below to THIS function: on return
  # (or a handled signal) zsh auto-restores the caller's prior trap disposition,
  # so we never clobber a trap the caller set around us. local_options keeps this
  # setopt itself local (no global leak).
  setopt local_options local_traps

  if ! have_tty; then
    IFS= read -rs __val </dev/tty 2>/dev/null || IFS= read -rs __val ||
      die "input aborted"
    printf -v "$__var" '%s' "$__val"
    return 0
  fi

  local __saved __ch
  # If we can't capture/drive the tty (no controlling terminal, restricted
  # environment), fall back to a blind no-echo read rather than spin.
  if ! __saved="$(stty -g </dev/tty 2>/dev/null)" || [[ -z "$__saved" ]]; then
    while :; do
      printf '%s%s%s ' "$C_BWH" "$__prompt" "$C_RES" >/dev/tty
      IFS= read -rs __val </dev/tty || die "input aborted"
      printf '\n' >/dev/tty
      [[ -n "$__val" ]] && break
      log_warn "a value is required"
    done
    printf -v "$__var" '%s' "$__val"
    return 0
  fi
  # Restore the tty on ANY exit, not just ^C: a TERM/HUP/QUIT (kill/timeout) or
  # a normal EXIT at the masked prompt would otherwise leave echo off, forcing
  # the user to blind-type `stty sane`. INT additionally reports the abort; the
  # other dispositions restore without dying so they don't clobber a normal
  # return's value (local_traps above restores the caller's dispositions on return).
  trap 'stty "$__saved" </dev/tty 2>/dev/null; printf "\n" >/dev/tty; die "input aborted"' INT
  trap 'stty "$__saved" </dev/tty 2>/dev/null' EXIT TERM HUP QUIT
  while :; do
    printf '%s%s%s ' "$C_BWH" "$__prompt" "$C_RES" >/dev/tty
    __val=""
    stty -echo -icanon min 1 time 0 </dev/tty
    while IFS= read -rk 1 __ch </dev/tty; do
      case "$__ch" in
        $'\n' | $'\r') break ;;
        $'\177' | $'\b') # Backspace / Delete
          ((${#__val})) && {
            __val="${__val[1,-2]}"
            printf '\b \b' >/dev/tty
          }
          ;;
        $'\025') # ^U — clear the whole entry
          while ((${#__val})); do
            __val="${__val[1,-2]}"
            printf '\b \b' >/dev/tty
          done
          ;;
        *)
          __val+="$__ch"
          printf '*' >/dev/tty
          ;;
      esac
    done
    stty "$__saved" </dev/tty
    printf '\n' >/dev/tty
    [[ -n "$__val" ]] && break
    log_warn "a value is required"
  done
  printf -v "$__var" '%s' "$__val"
}

# prompt::choice <varname> <prompt> <opt>... — accept only a listed option.
prompt::choice() {
  local __var="$1" __prompt="$2"
  shift 2
  local __opts=("$@") __val="" __o=""
  while :; do
    printf '%s%s%s (%s) ' "$C_BWH" "$__prompt" "$C_RES" "${(j:/:)__opts}" >/dev/tty
    IFS= read -r __val </dev/tty || die "input aborted"
    for __o in "${__opts[@]}"; do
      [[ "$__val" == "$__o" ]] && {
        printf -v "$__var" '%s' "$__val"
        return 0
      }
    done
    log_warn "choose one of: ${(j:, :)__opts}"
  done
}

# prompt::confirm <prompt> — return 0 on yes, 1 on no (default no).
prompt::confirm() {
  local __ans=""
  printf '%s%s%s [y/N] ' "$C_BWH" "$1" "$C_RES" >/dev/tty
  IFS= read -r __ans </dev/tty || return 1
  [[ "$__ans" == [yY] || "$__ans" == [yY][eE][sS] ]]
}
