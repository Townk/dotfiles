source "${0:A:h}/_lib.sh"

# I decide to make my MOTD screen a function to allow me to call it
# arbitrarially if I wanted.
function motd() {
    case $OSTYPE in
        darwin*)
            PWD_LAST_CHANGE=$(dscl -q . read $HOME SMBPasswordLastSet 2> /dev/null | grep -v ':$' | awk '{ sub(/^(.*:)? +/, ""); print $0 }')
            if [ -n "$PWD_LAST_CHANGE" ] && [ "$PWD_LAST_CHANGE" -eq "$PWD_LAST_CHANGE" ] 2>/dev/null; then
                PWD_LAST_CHANGE=$(( $(date +%s) - ($PWD_LAST_CHANGE / 10000000 - 11644473600) ))
            else
                PWD_LAST_CHANGE=$(( $(date +%s) - $(dscl -q . readpl $HOME accountPolicyData passwordLastSetTime | awk '{ sub(/^(.*:)? +/, ""); print $0 }') ))
            fi
            PWD_REMAINING_DAYS=$(LC_ALL=C /usr/bin/printf "%.*f\n" "0" $((365 - ($PWD_LAST_CHANGE / 86400))) )
            ;;
        *)
            PWD_REMAINING_DAYS=$(( ($(date -d "`chage -l $USER | grep "Last password change" | awk -F: '{ print $2; }'` + 90 days" +%s) - $(date -d "now" +%s)) / 86400 ))
            ;;
    esac
    PWD_REMAINING_SUFFIX="days"
    PWD_SEP="   "
    if [ $PWD_REMAINING_DAYS -gt 99 ]; then
        PWD_SEP=" "
        PWD_COLOR="\e[0;32m"
    elif [ $PWD_REMAINING_DAYS -gt 9 ]; then
        PWD_SEP="  "
        PWD_COLOR="\e[0;32m"
    elif [ $PWD_REMAINING_DAYS -gt 7 ]; then
        PWD_COLOR="\e[0;32m"
    elif [ $PWD_REMAINING_DAYS -gt 2 ]; then
        PWD_COLOR="\e[6;33m"
    else
        PWD_COLOR="\e[6;31m"
        if [ $PWD_REMAINING_DAYS -eq 1 ]; then
            PWD_REMAINING_SUFFIX="day"
        fi
    fi

    macchina
    echo -ne "  \e[0;34mPassword expires in:$PWD_SEP$PWD_COLOR"; echo "$PWD_REMAINING_DAYS $PWD_REMAINING_SUFFIX \e[0;0m\n"
}

# Quick function to print my outstanding additions to my terminal
#
# Here is the command template with no color markers to make it easy to change:
#
# 0                                                                                               98
# --------------------------------------------------------------------------------------------------
#  Available Commands%f
#
#  SYSTEM                         󰇺 PROCESSORS                      UTILITIES
#   ------                           ----------                       ---------
#   tldr      - Extra help           jq      - JSON processor         7zz       - 7-Zip cli
#   btm       - 'top' (bottom)       gron    - JSON to list assign   eva       - Calculator
#   procs     - Processes 'ps'       xq      - XML processor          fd        - 'find'
#   duf       - Disk usage           yq      - YAML processor         fend      - Unit conversion
#   y         - Files (yazi)         pandoc  - Any text processor     gh        - GitHub cli
#                                                                     git       - Version control
#  NETWORK                        󰊪 VISUALIZERS                      grex      - RegEx generator
#   -------                          -----------                      hyperfine - Benchmark
#   bandwhich - Network use          jless   - JSON tree              rg        - 'grep' (ripgrep)
#   doggo     - DNS look-up          tokei   - Code metrics           t-rec     - Terminal recorder
#   gping     - Latency graph        tv      - csv (tidy-viewer)      unrar     - Handle .rar format
# --------------------------------------------------------------------------------------------------
function terminal_commands() {
    print -P -- "$C_BLU Available Commands$C_RES

${C_YEL} SYSTEM${C_RES}                         ${C_YEL}󰇺 PROCESSORS${C_RES}                     ${C_YEL} UTILITIES${C_RES}
  ${C_YEL}------${C_RES}                           ${C_YEL}----------${C_RES}                       ${C_YEL}---------${C_RES}
  ${C_BWH}btm${C_RES}       - 'top' (bottom)       ${C_BWH}jq${C_RES}      - JSON processor         ${C_BWH}7zz${C_RES}       - 7-Zip cli
  ${C_BWH}duf${C_RES}       - Disk usage 'du'      ${C_BWH}pandoc${C_RES}  - Any text processor     ${C_BWH}eva${C_RES}       - Calculator
  ${C_BWH}y${C_RES}         - Files (yazi)         ${C_BWH}gron${C_RES}    - JSON to list assign    ${C_BWH}fd${C_RES}        - 'find'
  ${C_BWH}procs${C_RES}     - Processes 'ps'       ${C_BWH}xq${C_RES}      - XML processor          ${C_BWH}fend${C_RES}      - Unit conversion
  ${C_BWH}tldr${C_RES}      - Extra help           ${C_BWH}yq${C_RES}      - YAML processor         ${C_BWH}gh${C_RES}        - GitHub cli
                                                                    ${C_BWH}git${C_RES}       - Version control
${C_YEL} NETWORK                        ${C_YEL}󰊪 VISUALIZERS                      ${C_BWH}grex${C_RES}      - RegEx generator
  ${C_YEL}-------                          ${C_YEL}-----------                      ${C_BWH}hyperfine${C_RES} - Benchmark
  ${C_BWH}bandwhich${C_RES} - Network use          ${C_BWH}jless${C_RES}   - JSON tree              ${C_BWH}rg${C_RES}        - 'grep' (ripgrep)
  ${C_BWH}doggo${C_RES}     - DNS look-up          ${C_BWH}tokei${C_RES}   - Code metrics           ${C_BWH}t-rec${C_RES}     - Terminal recorder
  ${C_BWH}gping${C_RES}     - Latency graph        ${C_BWH}tv${C_RES}      - csv (tidy-viewer)      ${C_BWH}unrar${C_RES}     - Handle .rar format
    "
}

# This function will update my current system derivation with the changes on my
# nix config repository.
function nixswitch() {
    print -P -- "\n${C_BLU}Nix System Switch\n-----------------${C_RES}\n"
    local _TARGET_DIR="$HOME/workplace/personal/config/dotfiles"
    local _OLD_DIR=$PWD
    local _SUCCESS=1
    [[ "$_TARGET_DIR" != "$_OLD_DIR" ]] && pushd ~/workplace/personal/config/dotfiles > /dev/null
    if darwin-rebuild switch --flake ~/workplace/personal/config/dotfiles; then
        _SUCCESS=0
    fi
    [[ "$PWD" != "$_OLD_DIR" ]] && popd > /dev/null
    if [[ $_SUCCESS -eq 0 ]]; then
        print -P -- "\nNew Nix derivation switched ${C_BWH}successfully${C_RES}!\n"
        print -P -- "Changes won't be in effect until you ${C_BWH}restart${C_RES} your ZSH session.\n"
        true
    else
        print -P -- "\n${C_RED}Error while switching to the new derivation!${C_RES}\n"
        print -P -- "It's recommended that you fix the issue and re-run '${C_BWH}nixswitch${C_RES}' in\n${C_BWH}this ZSH session${C_RES} before open a new one.\n"
        false
    fi
}

# This function will update my config flake sources, rebuild the necessary
# packages, and update the current system derivation with all the new packages.
function nixup() {
    print -P -- "\n${C_BLU}Nix System Update
-----------------${C_RES}

This command will update ${C_BWH}Homebrew${C_RES} and the configuration ${C_BWH}Flake${C_RES},
and then, it will switch to the new system derivation.

Is recommended that you check the configuration repo for changes, and
${C_BWH}commit${C_RES} then to guarantee configuration persistence.\n
    "
    local _TARGET_DIR="$HOME/workplace/personal/config/dotfiles";
    local _OLD_DIR=$PWD;
    local _SUCCESS=1
    [[ "$_TARGET_DIR" != "$_OLD_DIR" ]] && pushd ~/workplace/personal/config/dotfiles > /dev/null
    if brew upgrade && nix flake update; then
        _SUCCESS=0
    fi
    [[ "$PWD" != "$_OLD_DIR" ]] && popd > /dev/null
    if [[ $_SUCCESS -eq 0 ]]; then
        if nixswitch; then
            print -P -- "\nSystem updated ${C_BWH}successfully${C_RES}!\n"
            print -P -- "Is recommended that you check the configuration repo for changes, and" \
                "${C_BWH}commit${C_RES}\nthen to guarantee configuration persistence.\n"
            true
        else
            print -P -- "\n${C_RED}The flake update worked, but we got an error while switching" \
                "to\bthe new system!${C_RES}\n"
            false
        fi
    else
        print -P -- "\n${C_RED}Error while updating the Nix system!${C_RES}\n"
        false
    fi
}

function lolbanner {
    figlet -d $XDG_DATA_HOME/fonts/figlet -w $(stty size|awk '{ print $2 }') $@ | lolcat
}

# Helper function to create a directory and enter on it with one command
function take() {
  [[ $# == 1 ]] && mkdir -p -- "$1" && cd -- "$1"
}
compdef _directories take

function g { [[ $# = 0 ]] && git status --short . || git $*; }
compdef g=git

function gg {
    if [[ -x "./gradlew" ]]; then
        ./gradlew $@
    else
        gradle $@
    fi
}
compdef gg=gradle

function yy() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
            cd -- "$cwd"
    fi
    rm -f -- "$tmp"
}

function super-cd {
    local all_dots=${1//[^.]}
    if [[ $# -eq 0 ]]; then
        \builtin cd ~
    elif [[ "$1" == "-/" ]]; then
        \builtin cd -
    elif [[ "$1" == "-" ]]; then
        typeset -a prev_stack
        typeset -a zoxi_stack
        local next_dir=""
        prev_stack=($dirstack[@])
        zoxi_stack=($(zoxide query --list --exclude=$PWD))
        for ((i=0; i < ${#zoxi_stack[@]} && ${#prev_stack[@]} < 20; i++)); do
            if ! (($dirstack[(Ie)${zoxi_stack[$i]}])); then
                prev_stack=($prev_stack[@] ${zoxi_stack[$i]})
            fi
        done
        if [[ ${#prev_stack[@]} -gt 1 ]]; then
            next_dir="$(printf "%s\n" "${prev_stack[@]}" | -z4h-fzf --no-sort)"
            next_dir="${next_dir#$'\n'}"
        elif [[ ${#prev_stack[@]} -eq 1 ]]; then
            next_dir="${prev_stack[0]}"
        fi
        if [[ ! -z "$next_dir" ]]; then
            \builtin cd "$next_dir"
        fi
    elif [[ "$1" == ".." ]]; then
        local next_dir=$(for d in $(_CUR_DIR=${PWD%/*}; while [[ "${_CUR_DIR}" != "" ]]; do echo $_CUR_DIR; _CUR_DIR=${_CUR_DIR%/*}; done; echo "/"); do echo $d; done | -z4h-fzf)
        next_dir="${next_dir#$'\n'}"
        if [[ ! -z "$next_dir" ]]; then
            \builtin cd "$next_dir"
        fi
    elif [[ ${#all_dots} -gt 2 ]] && [[ ${#1} -eq ${#all_dots} ]]; then
        local next_dir=$(printf '../%.0s' {2..${#1}})
        \builtin cd $next_dir
    else
        \builtin cd $@
    fi
}
compdef _directories super-cd

function fzf-preview {
  if [[ -d "$1" ]]; then
    eza -F -h --group-directories-first --icons --hyperlink --tree --color=always "$1" | head -200
  elif [[ ! -f "$1" ]]; then
    echo "Nothing to preview"
  else
    (bat --theme=OneHalfDark --style=numbers,changes --color=always "$1" || highlight -O ansi -l "$1" || coderay "$1" || rougify "$1" || cat "$1") 2> /dev/null | head -200
  fi
}

function update-system {
    print -P -- "\n${C_BLU}System Update
-------------${C_RES}"
  print -P -- "\n  Updating Homebrew sources...\n"
  brew update || die "${C_RED}Error${C_RES}: Failed to update Homebrew!" || return
  print -P -- "\n🍻 Upgrade Homebrew Bundle...\n"
  cat ~/.config/brewfile/Brewfile* | brew bundle install -q --cleanup --upgrade --file=-
  [[ $? -eq 0 ]] || die "${C_RED}Error${C_RES}: Failed to upgrade Homebrew Bundle!" || return
  print -P -- "\n🍺 Upgrade Homebrew casks...\n"
  brew upgrade --cask --greedy-auto-updates --no-quarantine || die "${C_RED}Error${C_RES}: Failed to upgrade Homebrew casks!" || return
  print -P -- "\n🧹 Cleanning up Homebrew artifacts...\n"
  brew cleanup -q --prune=all || die "${C_RED}Error${C_RES}: Failed to clean up Homebrew files!" || return
  print -P -- "\n🦆 Upgrade Yazi plugins...\n"
  ya pkg upgrade || die "${C_RED}Error${C_RES}: Failed to upgrade Yazi plugins!" || return
  print -P -- "\n👍 System updated ${C_BWH}successfully${C_RES}!\n"

  if command -v update-work-system >/dev/null; then
    update-work-system
  fi
}

function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
	rm -f -- "$tmp"
}
