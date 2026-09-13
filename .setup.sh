#!/bin/bash
set -eufo pipefail

# .setup.sh — fresh-machine bootstrap: make this machine able to run chezmoi
# against this repo. Two INDEPENDENT axes decide what happens:
#
#   platform (uname -s) — HOW tools get installed.
#       Darwin: Xcode CLT + Homebrew + `brew install chezmoi`.
#       Linux:  apt base packages + the chezmoi and mise installers + zsh as
#               the login shell.
#   kind (asked of the repo AFTER the clone) — WHO finishes the job.
#       human:    bootstrap Brewfile, 1Password/gh auth gates, secrets
#                 self-onboard, then the heavy `chezmoi apply`.
#       headless: stop here and hand over to an operator's `system-onboard`,
#                 which renders the secrets fragment and runs the first apply.
#
# The only profile name in this file is the documented macOS no-TTY default
# below; the profile→kind mapping is never tabulated here — kind comes from
# .chezmoitemplates/profile-traits.tmpl, which FAILS on an unknown profile —
# so a typo dies at the lookup, before any lifecycle step.
#
# Invocation (a `curl … | bash -s -- …` one-liner, or streamed by
# system-onboard over ssh with `bash -s`):
#   .setup.sh --profile <name>

# --- arguments ---------------------------------------------------------------
# --profile <p> | --profile=<p>  → CHEZMOI_PROFILE=<p> (chezmoi init skips
# its prompt). Anything else is an error. With no flag: Darwin keeps the
# documented `curl | bash` default (prompt on a TTY, the macOS default below
# without one); Linux refuses without a TTY — a headless host must be explicit.
OS="$(uname -s)"
PROFILE=""
while (($#)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌  --profile needs a value" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#--profile=}"
      shift
      ;;
    -h | --help)
      echo "usage: .setup.sh [--profile <name>]"
      exit 0
      ;;
    *)
      echo "❌  Unknown argument: $1 (use --profile <name>)" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$PROFILE" ]]; then
  export CHEZMOI_PROFILE="$PROFILE"
  echo "🎯  Profile: $PROFILE (from --profile)"
elif [[ ! -t 0 ]]; then
  if [[ "$OS" == Darwin ]]; then
    # No TTY for an interactive prompt; default below so a `curl … | bash`
    # invocation doesn't fail on an unanswerable prompt.
    export CHEZMOI_PROFILE=personal
    echo "🎯  Profile: personal (default; no --profile and no TTY)"
  else
    echo "❌  No --profile and no TTY: a Linux host must name its profile explicitly." >&2
    exit 2
  fi
else
  echo "🎯  Profile: (chezmoi init will prompt)"
fi

echo "🚀  Setting up @thiagoalves dotfiles."

# Run a privileged command: directly when already root, via sudo otherwise.
# The same three lines live in two run-scripts — this file runs BEFORE the
# clone exists, so it cannot source anything from the repo.
as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# --- platform prerequisites --------------------------------------------------
echo "⚙️  Preparing user directories..."
mkdir -p ~/.config ~/.cache ~/.local/{bin,share,state}
echo "✅  XDG standard directories present and ready to use."
# The Linux installers land in ~/.local/bin; make it visible for the rest of
# this run (the deployed zsh env takes over afterwards).
export PATH="$HOME/.local/bin:$PATH"

case "$OS" in
  Darwin)
    if xcode-select -p &>/dev/null; then
      echo "✅  Xcode command line tools are already installed."
    else
      echo "🔧  Installing Xcode command line tools..."
      xcode-select --install &>/dev/null
      while ! xcode-select -p &>/dev/null; do
        sleep 5
      done
      echo "✅  Xcode command line tools installed successfully."
    fi

    if command -v brew >/dev/null 2>&1; then
      echo "✅  Homebrew is already installed."
    else
      echo "🍺  Installing Homebrew"
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      echo "✅  Homebrew installed successfully."
    fi

    # Make brew available on PATH for the current shell. The Homebrew installer
    # only configures future shells; without this, the next `brew install` line
    # would error on a truly fresh machine.
    if [ -x "/opt/homebrew/bin/brew" ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x "/usr/local/bin/brew" ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi

    # chezmoi is also declared in Brewfile.bootstrap for idempotency, but it
    # needs to exist before that file is reachable — `chezmoi init` is what
    # clones this repo into ~/.local/share/chezmoi/ (where the Brewfile lives).
    if command -v chezmoi >/dev/null 2>&1; then
      echo "✅  Chezmoi is already installed."
    else
      echo "⚪️  Installing Chezmoi"
      brew install chezmoi
    fi
    ;;
  Linux)
    command -v apt-get >/dev/null 2>&1 ||
      { echo "❌  Only apt-based Linux is supported by this bootstrap." >&2; exit 1; }
    # DEBIAN_FRONTEND stops debconf dialogs; NEEDRESTART_SUSPEND stops apt's
    # post-invoke hook from asking which daemons to restart. Both would block a
    # tty-attached run forever. `env` carries them through sudo's env_reset.
    echo "📦  Installing base packages via apt (zsh, git, curl)..."
    as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
      apt-get install -y -qq zsh git curl ca-certificates

    if command -v chezmoi >/dev/null 2>&1; then
      echo "✅  Chezmoi is already installed."
    else
      echo "⚪️  Installing Chezmoi into ~/.local/bin"
      sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    fi

    # mise provisions the language runtimes AND, on headless Linux, the whole
    # CLI toolbox (the Brewfile's job on a Mac). Its installer lands in
    # ~/.local/bin/mise.
    if command -v mise >/dev/null 2>&1; then
      echo "✅  mise is already installed."
    else
      echo "🛠️  Installing mise into ~/.local/bin"
      curl -fsSL https://mise.run | sh
    fi

    # Every rendered shell config assumes zsh as the login shell. chsh asks no
    # password for root; a non-root user is prompted, so only try with a TTY.
    zsh_path="$(command -v zsh)"
    if [[ "${SHELL:-}" == "$zsh_path" ]]; then
      echo "✅  zsh is already the login shell."
    elif [[ "$(id -u)" -eq 0 || -t 0 ]]; then
      echo "🐚  Making zsh the login shell..."
      chsh -s "$zsh_path" "$(id -un)"
    else
      echo "ℹ️  No TTY: leaving the login shell alone. Later, run: chsh -s $zsh_path"
    fi
    ;;
  *)
    echo "❌  Unsupported platform: $OS" >&2
    exit 1
    ;;
esac

# --- clone and init ----------------------------------------------------------
# `chezmoi init <user>` does two things:
#   - First run: clones the dotfiles repo into ~/.local/share/chezmoi/ (https;
#     the deployed git config rewrites pushes to ssh).
#   - Subsequent runs: re-renders the init template (which is how a profile
#     change via --profile takes effect).
# On re-runs we explicitly `chezmoi update` first to pull origin.
#
# We deliberately stop short of `apply` here — apply needs to fire AFTER the
# bootstrap tools are installed and (human) the interactive auth gates are
# cleared, or (headless) the operator has rendered the secrets fragment.
if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
  echo "ℹ️  Chezmoi already initialized, pulling latest changes..."
  chezmoi update --apply=false
  chezmoi init Townk
  echo "✅  Chezmoi source updated and config regenerated"
else
  chezmoi init Townk
  echo "✅  Chezmoi initialized"
fi

# --- kind lookup -------------------------------------------------------------
# Ask the repo just cloned whether this profile is headless. The single source
# of truth is .chezmoitemplates/profile-traits.tmpl; it FAILS the render on an
# unknown profile, so a typo dies here, before any lifecycle step.
HEADLESS="$(chezmoi execute-template \
  '{{ (includeTemplate "profile-traits.tmpl" . | fromJson).headless }}')" || {
  echo "❌  Could not resolve this profile's traits (unknown profile?)." >&2
  echo "    Re-run with a valid --profile <name>; until then every chezmoi" >&2
  echo "    command on this machine will fail the render." >&2
  exit 1
}

if [[ "$HEADLESS" == true ]]; then
  # --- lifecycle: headless ---------------------------------------------------
  # Secrets and the first apply are operator-driven: the first `mise install`
  # must run with the GitHub token live, and only the operator's onboard can
  # render that fragment on a headless box.
  RESOLVED_PROFILE="$(chezmoi execute-template '{{ .profile }}')"
  cat <<EOF
ℹ️  Headless profile ($RESOLVED_PROFILE): this machine is bootstrapped
    (chezmoi, mise, zsh, source clone). Secrets and the first apply are
    operator-driven. From a trusted operator host run:
      system-onboard --alias <alias> --hostname <host> --profile $RESOLVED_PROFILE [--user <login>]
EOF
  exit 0
fi

# --- lifecycle: human --------------------------------------------------------
# Install the bootstrap Brewfile (chezmoi, mise, gh, 1password-cli, tap).
# These are the tools the rest of `.setup.sh` itself needs PLUS the minimal
# set the chezmoi run_once bootstrap depends on (`mise` so `mise install` can
# provision Python/Node/Go/Rust/uv before system-update's ecosystem syncs
# run). Read from the chezmoi source location since `chezmoi apply` hasn't
# deployed files yet. Homebrew-only: a human Linux machine has no equivalent
# yet, so the step is skipped there and the gates below hint instead.
if command -v brew >/dev/null 2>&1; then
  echo "🍻  Installing bootstrap Brewfile..."
  brew bundle install --file="$HOME/.local/share/chezmoi/home/dot_config/packages/Brewfile.bootstrap"
else
  echo "ℹ️  No Homebrew on this platform: skipping the bootstrap Brewfile (op, gh, mas, jq, yq)."
fi

# Interactive auth gates. Front-loaded so the user clears them while
# their attention is on the install. After these, the run_once
# bootstrap can run unattended.
#
# Both gates are inherently interactive: the 1Password gate needs the
# desktop app plus a manual settings toggle, and `gh auth login` drives a
# browser/device flow. Under `curl … | bash` stdin IS the piped script
# text, so a bare `read` in these loops would swallow the rest of the
# script and — under `set -e` — exit silently at EOF, before `chezmoi
# apply` ever runs. So gate the loops on an interactive TTY (mirroring the
# secrets self-onboard below): with no terminal, print an actionable hint
# and skip rather than block; with a TTY, read the prompt from /dev/tty so
# even a piped stdin can never be consumed. A gate whose CLI is not
# installed at all hints instead of looping.
if ! command -v op >/dev/null 2>&1; then
  echo "ℹ️  1Password CLI (op) is not installed: skipping its auth gate."
  echo "    After setup, install it, enable 'Integrate with 1Password CLI', then run:"
  echo "        op signin"
elif op account list &>/dev/null; then
  echo "✅ 1Password CLI is already integrated and authenticated."
elif [ -t 0 ]; then
  while ! op account list &>/dev/null; do
    echo "--------------------------------------------------------"
    echo "⚠️  ACTION REQUIRED: Manual Step Needed"
    echo "1. Open 1Password for Mac."
    echo "2. Go to Settings > Developer."
    echo "3. Check 'Integrate with 1Password CLI'."
    echo "4. Check 'Use the SSH provider'."
    echo "--------------------------------------------------------"
    read -r -p "Press [Enter] once you have enabled these settings to continue..." </dev/tty
  done
  echo "✅ 1Password CLI is already integrated and authenticated."
else
  echo "ℹ️  No TTY: skipping the 1Password CLI auth gate."
  echo "    After setup, enable 'Integrate with 1Password CLI' and 'Use the SSH"
  echo "    provider' in 1Password for Mac (Settings > Developer), then run:"
  echo "        op signin"
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ℹ️  GitHub CLI (gh) is not installed: skipping its auth gate."
  echo "    After setup, install it and run: gh auth login"
elif gh auth token &>/dev/null; then
  echo "✅  GitHub CLI is authenticated and ready to use."
elif [ -t 0 ]; then
  while ! gh auth token &>/dev/null; do
    echo "ℹ️  GitHub not authenticated. Please, complete the GitHub login now..."
    gh auth login
  done
  echo "✅  GitHub CLI is authenticated and ready to use."
else
  echo "ℹ️  No TTY: skipping the GitHub CLI auth gate."
  echo "    After setup, run: gh auth login"
fi

# Self-onboard this machine's secrets BEFORE the heavy apply. The first
# run_once install (mise install → system-update) hits GitHub hard and wants
# MISE_GITHUB_TOKEN / HOMEBREW_GITHUB_API_TOKEN, which are delivered only via
# the rendered secrets.d fragment. system-onboard --local provisions the
# per-machine slot + 1Password fragment, sets secretsSlot (chezmoi init), and
# makes this machine an operator; --no-apply leaves the single heavy apply
# below to render the fragment with the tokens live.
#
# system-onboard and its dependency chain aren't on disk until chezmoi applies
# them, so deploy exactly that chain first (a targeted apply runs no run_*
# scripts and resolves no dependencies itself): system-onboard sources
# system-secrets-common.zsh, which sources common.zsh and prompt-common.zsh.
# It's interactive (SA token / op:// prompts); under `curl | bash` there's no
# TTY, so skip with a hint. Never block bootstrap on its outcome.
# --no-commit: git identity and the GPG signing key are provisioned by the full
# apply below, so committing the rendered fragment here would fail (or sign
# with an auto-detected hostname identity); the uncommitted .tmpl still lands
# in the source dir and the heavy apply renders it with the tokens live.
# The mkdir matters: a targeted apply does not create parent directories, and
# on a fresh machine ~/.local/{lib,bin} don't exist yet.
mkdir -p "$HOME/.local/lib" "$HOME/.local/bin"
chezmoi apply "$HOME/.local/lib/common.zsh" \
              "$HOME/.local/lib/prompt-common.zsh" \
              "$HOME/.local/lib/system-secrets-common.zsh" \
              "$HOME/.local/bin/system-onboard" 2>/dev/null || true
if [ -t 0 ] && [ -x "$HOME/.local/bin/system-onboard" ]; then
  echo "🔑  Self-onboarding this machine's secrets..."
  if "$HOME/.local/bin/system-onboard" --local --no-apply --no-commit; then
    echo "✅  Secrets provisioned"
  else
    echo "⚠️  Self-onboarding did not complete; finish later with: system-onboard --local"
  fi
else
  echo "ℹ️  No TTY (or tooling missing): skipping secrets self-onboard."
  echo "    After setup, run: system-onboard --local"
fi

# Now that all prereqs are in place, deploy files and fire the run_once
# bootstrap script (mise install → system-update → rust@nightly).
echo "📂  Applying chezmoi configuration..."
chezmoi apply
echo "✅  Chezmoi applied"
