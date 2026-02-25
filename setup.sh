#!/usr/bin/env bash
set -e

REPO_URL="https://github.com/ukane-philemon/bpscripts.git"
INSTALL_DIR="$HOME/bpscripts"

OS="$(uname)"

install_brew_macos() {
  if [[ "$OS" != "Darwin" ]]; then
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Installing..."

    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ $? -ne 0 ]]; then
      echo "Homebrew installation failed."
      exit 1
    fi
  fi

  # Properly load brew into PATH
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  echo "Homebrew is ready...nex!"
}

if [[ "$OS" == "Darwin" ]] && ! command -v brew >/dev/null 2>&1; then
  install_brew_macos
fi

install_git_if_missing() {
  if command -v git >/dev/null 2>&1; then
    return
  fi

  echo "Git not found. Installing git..."

  if [[ "$OS" == "Darwin" ]]; then
    brew install git
  else
    sudo apt update
    sudo apt install -y git
  fi

  git config --global pull.rebase true
}

# If install.sh does not exist, we are running standalone via curl
if [[ ! -f "./install.sh" ]]; then
  echo "Bootstrapping full installer..."

  install_git_if_missing

  if [[ ! -d "$INSTALL_DIR" ]]; then
    git clone "$REPO_URL" "$INSTALL_DIR"
  else
    echo "Installer already exists. Updating..."
    cd "$INSTALL_DIR"
    git pull
    cd -
  fi

  cd "$INSTALL_DIR"
  chmod +x *.sh

  exec ./setup.sh "$@"
fi

echo "Running full setup..."

./install.sh
./simnet.sh