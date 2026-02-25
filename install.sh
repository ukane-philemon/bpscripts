#!/usr/bin/env bash
set -e

ROOT="$HOME/nbtest"
BIN_DIR="$HOME/crypto-bin"
DEX="$ROOT/dcrdex"
GREEN="\033[0;32m"

OS="$(uname)"

# Bitcoin download page uses a different representation of operating systems and arch.
BTC_OS="$(uname)"
BTC_ARCH="$(uname -m)"

# Decred download page on Github uses a different representation of operating systems and arch.
DCR_OS="$(uname)"
DCR_ARCH="$(uname -m)"

ARCH_RAW="$(uname -m)"

log_ok() {
  echo -e "[${GREEN}✔${NC}] $1"
}

fail() { echo "[✖] $1"; exit 1; }

lower_os() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

install_brew_macos() {
  if [[ "$OS" != "Darwin" ]]; then
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    log_ok "Homebrew not found. Installing..."

    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ $? -ne 0 ]]; then
      echo "Homebrew installation failed."
      exit 1
    fi
  fi

  # Properly load brew into PATH (handles Intel + Apple Silicon)
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  log_ok "Homebrew is ready...next!"
}

if [[ "$OS" == "Darwin" ]] && ! command -v brew >/dev/null 2>&1; then
  install_brew_macos
fi

# Bitcoin download page uses different naming for operating systems.
if [[ "$BTC_OS" == "Darwin" ]]; then
    BTC_OS="apple-darwin"
elif [[ "$BTC_OS" == "Linux" ]]; then
    BTC_OS="linux-gnu"
else
  echo "Unsupported architecture for Bitcoin: "$BTC_OS""
  exit 1
fi

# Map system arch to format used by Decred download page
if [[ "$ARCH_RAW" == "x86_64" ]]; then
  DCR_ARCH="amd64"
elif [[ "$ARCH_RAW" == "arm64" || "$ARCH_RAW" == "aarch64" ]]; then
  DCR_ARCH="arm64"
else
  echo "Unsupported architecture for Decred: $ARCH_RAW"
  exit 1
fi

# Map system arch to format used by Bitcoin download page
if [[ "$ARCH_RAW" == "x86_64" ]]; then
  BTC_ARCH="x86_64"
elif [[ "$ARCH_RAW" == "arm64" || "$ARCH_RAW" == "aarch64"  ]]; then
  BTC_ARCH="arm64"
else
  echo "Unsupported architecture for Bitcoin Core: $ARCH_RAW"
  exit 1
fi

########################################
# Install base dependencies
########################################

install_if_missing() {
  if ! command -v $1 >/dev/null 2>&1; then
    log_ok "Installing $1..."
    if [[ "$OS" == "Darwin" ]]; then
      brew install $2
      log_ok "$1 installed...next!"
    else
      sudo apt update
      sudo apt install -y $2
      log_ok "$1 installed...next!"
    fi

    if [[ "$1" == "git" ]]; then
      git config --global pull.rebase true
    fi
  else
    log_ok "$1 exists...next!"
  fi
}

install_dotnet_if_missing() {
  if ! command -v dotnet >/dev/null 2>&1; then
    log_ok "Installing dotnet..."
    if [[ "$OS" == "Darwin" ]]; then
      brew install dotnet-sdk
      log_ok "dotnet installed...next!"
    else
      sudo apt update
      sudo apt install -y dotnet-sdk-10.0 dotnet-runtime-10.0 dotnet-host-10.0 
      log_ok "dotnet installed...next!"
    fi
  else
    log_ok "dotnet exists...next!"
  fi
}

install_if_missing git git
install_if_missing curl curl
install_if_missing tmux tmux
install_dotnet_if_missing

########################################
# Install PostgreSQL
########################################

PG_VERSION="15"

# macOS (Homebrew)
if [[ "$OS" == "Darwin" ]]; then
  log_ok "Detected macOS"

  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is required but not installed."
  fi

  if [[ -n "$PG_VERSION" ]]; then
    FORMULA="postgresql@$PG_VERSION"
  else
    FORMULA="postgresql"
  fi

  if ! brew list "$FORMULA" >/dev/null 2>&1; then
    log_ok "Installing $FORMULA..."
    brew install "$FORMULA"
  else
    log_ok "$FORMULA already installed"
  fi

  brew services start "$FORMULA"

  # Add binary path if versioned
  if [[ -n "$PG_VERSION" ]]; then
    PG_BIN_PATH="$(brew --prefix)/opt/$FORMULA/bin"
    export PATH="$PG_BIN_PATH:$PATH"
  fi

  log_ok "PostgreSQL installed and running (macOS)...next!"

# Linux (Debian / Ubuntu)
elif [[ "$OS" == "Linux" ]]; then
  log_ok "Detected Linux"

  if ! command -v apt >/dev/null 2>&1; then
    fail "This script currently supports Debian/Ubuntu only."
  fi

  if ! command -v psql >/dev/null 2>&1; then
    log_ok "Installing PostgreSQL from distro repository..."
    sudo apt update
    sudo apt install -y postgresql postgresql-contrib postgresql-client-common
  else
    log_ok "PostgreSQL already installed."
  fi

  sudo systemctl enable postgresql
  sudo systemctl start postgresql

  log_ok "PostgreSQL installed and running (Linux)....next!"
fi

# Confirm psql was installed properly
if command -v psql >/dev/null 2>&1; then
  VERSION=$(psql --version)
  log_ok "Verified PostgreSQL version $VERSION :)"
else
  fail "psql not found after installation :("
fi

########################################
# Set the correct profile file
########################################

CURRENT_SHELL="$(basename "$SHELL")"

if [[ "$CURRENT_SHELL" == "zsh" ]]; then
  PROFILE_FILE="$HOME/.zshrc"
elif [[ "$CURRENT_SHELL" == "bash" ]]; then
  PROFILE_FILE="$HOME/.bashrc"
else
  PROFILE_FILE="$HOME/.profile"
fi

########################################
# Download Decred + Bitcoin executables for dcrdex harness
########################################

mkdir -p $BIN_DIR
cd $BIN_DIR

DCR_VERSION="v2.1.3"
BTC_VERSION="30.2"

if ! command -v dcrd >/dev/null 2>&1; then
 log_ok "Downloading Decred harness executables..."
  curl -LO https://github.com/decred/decred-binaries/releases/latest/download/decred-$(lower_os "$DCR_OS")-${DCR_ARCH}-${DCR_VERSION}.tar.gz
  tar -xzf decred-$(lower_os "$DCR_OS")-${DCR_ARCH}-${DCR_VERSION}.tar.gz
  log_ok "Decred harness executables downloaded...next!"
else
 log_ok "Dcrd harness executables exists...next!"
fi

if ! command -v bitcoind >/dev/null 2>&1; then
  log_ok "Downloading Bitcoin harness executables..."
  curl -LO https://bitcoincore.org/bin/bitcoin-core-${BTC_VERSION}/bitcoin-${BTC_VERSION}-${BTC_ARCH}-$(lower_os "$BTC_OS").tar.gz
  tar -xzf bitcoin-${BTC_VERSION}-${BTC_ARCH}-$(lower_os "$BTC_OS").tar.gz
   log_ok "Bitcoin harness executables downloaded...next!"
else
 log_ok "Bitcoin harness executables exists...next!"
fi

########################################
# Persist PATH
########################################

EXPORT_LINE="export PATH=\"$BIN_DIR/decred-$(lower_os "$DCR_OS")-${DCR_ARCH}-${DCR_VERSION}:$BIN_DIR/bitcoin-${BTC_VERSION}/bin:\$PATH\""

# Only append if not already present
if ! grep -q "crypto-bin" "$PROFILE_FILE" 2>/dev/null; then
  echo "" >> "$PROFILE_FILE"
  echo "# Added by nbx-dcr installer" >> "$PROFILE_FILE"
  echo "$EXPORT_LINE" >> "$PROFILE_FILE"
  log_ok "PATH updated in $PROFILE_FILE...next!"
else
  log_ok "PATH already configured in $PROFILE_FILE...next!"
fi

# Apply immediately for current shell
export PATH="$BIN_DIR/decred-$(lower_os "$DCR_OS")-${DCR_ARCH}-${DCR_VERSION}:$BIN_DIR/bitcoin-${BTC_VERSION}/bin:$PATH"

########################################
# Clone + Build Services
########################################

clone_repo() {
  local dir="$1"
  local url="$2"
  local branch="$3"

  if [[ ! -d "$dir" ]]; then
    log_ok "Cloning $dir..."
    if [[ -n "$branch" ]]; then
      git clone -b "$branch" "$url" "$dir"
    else
      git clone "$url" "$dir"
    fi
    log_ok "$dir cloned successfully...next!"
  else
    cd "$dir" && git pull # attempt an update
    log_ok "$dir already exists...next!"
  fi
}

mkdir -p $ROOT
cd $ROOT

clone_repo NBitcoin https://github.com/itswisdomagain/NBitcoin.git dcr
clone_repo NBXplorer https://github.com/itswisdomagain/NBXplorer.git dcr
clone_repo btcpayserver https://github.com/itswisdomagain/btcpayserver.git dcr
clone_repo dcrdex https://github.com/decred/dcrdex.git

cd $ROOT/NBXplorer && ./build.sh
cd $ROOT/btcpayserver && ./build.sh

echo ""
echo "✅ Installation complete."
echo "[→] Next: Run ./simnet.sh"