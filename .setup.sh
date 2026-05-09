#!/bin/bash
set -eufo pipefail

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

if which -s "chezmoi"; then
  echo "✅  Chezmoi is already installed."
else
  echo "⚪️  Installing Chezmoi"
  brew install chezmoi
fi

if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
  echo "ℹ️  Chezmoi already initialized, pulling latest changes..."
  chezmoi update
  echo "✅  Chezmoi updated"
else
  # `chezmoi init <user>` clones https://github.com/<user>/dotfiles.git
  # into ~/.local/share/chezmoi/, which is the source path the rest of
  # this script (and the run_once bootstrap inside chezmoi apply) assumes.
  chezmoi init Townk
  chezmoi apply
  echo "✅  Chezmoi initialized"
fi

# Install the bootstrap Brewfile (gh, 1password-cli, tap). These are the
# tools the rest of `.setup.sh` itself needs — `gh` to download `bin`, and
# `op` to gate on 1Password CLI integration. Read from the chezmoi source
# location since the deployed copy at ~/.config/brewfile/ may already be
# in place by now (after the `chezmoi apply` above), but referencing the
# source makes this robust to the deploy-order changing.
echo "🍻  Installing bootstrap Brewfile..."
brew bundle install --file="$HOME/.local/share/chezmoi/dot_config/brewfile/Brewfile.bootstrap"

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

if [ -x "$HOME/.local/bin/bin" ]; then
  echo "✅  bin is already installed"
else
  echo "⚪️  Installing 'bin'"
  gh release download --repo marcosnils/bin --pattern '*darwin_arm64' -O bin_darwin_arm64
  chmod +x bin_darwin_arm64
  ./bin_darwin_arm64 install github.com/marcosnils/bin
  rm -rf ./bin_darwin_arm64
fi
