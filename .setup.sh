#!/bin/bash
set -eufo pipefail

# Parse profile selection from CLI:
#   --work       → chezmoi `.profile` data set to "work"
#   --personal   → chezmoi `.profile` data set to "personal"
#   (no flag)    → prompt the user via chezmoi's init template
#                  (or default to personal when no TTY is available)
#
# The chezmoi init template reads CHEZMOI_PROFILE; setting it here
# is what bypasses the prompt for explicit invocations like:
#   curl … | bash -s -- --work
PROFILE=""
for arg in "$@"; do
  case "$arg" in
    --work)     PROFILE="work" ;;
    --personal) PROFILE="personal" ;;
    *)          echo "⚠️  Ignoring unknown argument: $arg" >&2 ;;
  esac
done

if [[ -n "$PROFILE" ]]; then
  export CHEZMOI_PROFILE="$PROFILE"
  echo "🎯  Profile: $PROFILE (from CLI)"
elif [[ ! -t 0 ]]; then
  # No TTY for an interactive prompt; default to personal so a
  # `curl … | bash` invocation doesn't fail on an unanswerable prompt.
  export CHEZMOI_PROFILE="personal"
  echo "🎯  Profile: personal (default; no --work/--personal flag and no TTY)"
else
  echo "🎯  Profile: (chezmoi init will prompt)"
fi

echo "🚀  Setting up @thiagoalves dotfiles."

echo "⚙️  Preparing user directories..."
mkdir -p ~/.config
mkdir -p ~/.cache
mkdir -p ~/.local/{bin,share,state}
echo "✅  XDG standard directories present and ready to use."

if xcode-select -p &> /dev/null; then
  echo "✅  Xcode command line tools are already installed."
else
  echo "🔧  Installing Xcode command line tools..."
  xcode-select --install &> /dev/null

  while ! xcode-select -p &> /dev/null; do
    sleep 5
  done
  echo "✅  Xcode command line tools installed successfully."
fi

if which -s "brew"; then
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
if which -s "chezmoi"; then
  echo "✅  Chezmoi is already installed."
else
  echo "⚪️  Installing Chezmoi"
  brew install chezmoi
fi

# `chezmoi init <user>` does two things:
#   - First run: clones the dotfiles repo into ~/.local/share/chezmoi/.
#   - Subsequent runs: re-renders the init template (which is how a
#     profile change via --work / --personal takes effect).
# On re-runs we explicitly `chezmoi update` first to pull origin.
#
# We deliberately stop short of `apply` here — apply needs to fire
# AFTER the bootstrap Brewfile is installed, `bin` is on disk, and the
# interactive auth gates are cleared.
if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
  echo "ℹ️  Chezmoi already initialized, pulling latest changes..."
  chezmoi update --apply=false
  chezmoi init Townk
  echo "✅  Chezmoi source updated and config regenerated"
else
  chezmoi init Townk
  echo "✅  Chezmoi initialized"
fi

# Install the bootstrap Brewfile (chezmoi, mise, gh, 1password-cli, tap).
# These are the tools the rest of `.setup.sh` itself needs PLUS the
# minimal set the chezmoi run_once bootstrap depends on (`mise` so
# `mise install` can provision Python/Node/Go/Rust/uv before
# system-update's ecosystem syncs run). Read from the chezmoi source
# location since `chezmoi apply` hasn't deployed files yet.
echo "🍻  Installing bootstrap Brewfile..."
brew bundle install --file="$HOME/.local/share/chezmoi/dot_config/packages/Brewfile.bootstrap"

# Install `bin` (https://github.com/marcosnils/bin). Done before
# `chezmoi apply` so that `system-update`'s `bin update` step (invoked
# from the run_once bootstrap) sees `bin` on PATH. Fetched via the
# anonymous GitHub releases API to avoid a hard dependency on
# `gh auth login` running first.
if [ -x "$HOME/.local/bin/bin" ]; then
  echo "✅  bin is already installed"
else
  echo "⚪️  Installing 'bin'"
  arch=$(uname -m)
  case "$arch" in
    arm64)  asset_suffix="darwin_arm64" ;;
    x86_64) asset_suffix="darwin_amd64" ;;
    *)      echo "❌  Unsupported architecture for bin: $arch" >&2; exit 1 ;;
  esac
  asset_url=$(
    curl -fsSL https://api.github.com/repos/marcosnils/bin/releases/latest \
      | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+'"$asset_suffix"'"' \
      | sed -E 's/.*"([^"]+)"$/\1/' \
      | head -1
  )
  [ -n "$asset_url" ] || { echo "❌  Could not resolve bin release asset URL" >&2; exit 1; }
  tmp_bin=$(mktemp)
  curl -fsSL "$asset_url" -o "$tmp_bin"
  chmod +x "$tmp_bin"
  "$tmp_bin" install github.com/marcosnils/bin
  rm -f "$tmp_bin"
fi

# Interactive auth gates. Front-loaded so the user clears them while
# their attention is on the install. After these, the run_once
# bootstrap can run unattended.
while ! op account list &>/dev/null; do
  echo "--------------------------------------------------------"
  echo "⚠️  ACTION REQUIRED: Manual Step Needed"
  echo "1. Open 1Password for Mac."
  echo "2. Go to Settings > Developer."
  echo "3. Check 'Integrate with 1Password CLI'."
  echo "4. Check 'Use the SSH provider'."
  echo "--------------------------------------------------------"
  read -r -p "Press [Enter] once you have enabled these settings to continue..."
done
echo "✅ 1Password CLI is already integrated and authenticated."

while ! gh auth token &>/dev/null; do
  echo "ℹ️  GitHub not authenticated. Please, complete the GitHub login now..."
  gh auth login
done
echo "✅  GitHub CLI is authenticated and ready to use."

# Now that all prereqs are in place, deploy files and fire the run_once
# bootstrap script (mise install → system-update → rust@nightly).
echo "📂  Applying chezmoi configuration..."
chezmoi apply
echo "✅  Chezmoi applied"
