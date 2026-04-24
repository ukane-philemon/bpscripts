#!/usr/bin/env bash
set -e

########################################
# BTCPayServer Decred Plugin — One-Click End-to-End Test
#
# Usage:
#   ./e2etest.sh [command]
#
# No prior installs assumed. The script installs all dependencies,
# builds / downloads all binaries, and runs end-to-end.
########################################

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

########################################
# Config — override via env vars
########################################

ROOT="${E2E_ROOT:-$HOME/btcpay-dcr-e2e}"
PLUGIN_DIR="$ROOT/btcpayserver-decred-plugin"
DCRDEX_DIR="$ROOT/dcrdex"
BIN_DIR="$ROOT/bin"
PLUGIN_INSTALL_DIR="$HOME/.btcpayserver/Plugins/BTCPayServer.Plugins.Decred"
HARNESS_CTL_DIR="$HOME/dextest/dcr/harness-ctl"

# Decred pre-built release to download when dcrd/dcrwallet/dcrctl are not in PATH
DCR_VERSION="v2.1.3"
DEFAULT_PLUGIN_REPO_URL="https://github.com/bisoncraft/btcpayserver-decred-plugin"

# dcrdex simnet RPC endpoints (set by the harness)
DCR_NODE_HOST="127.0.0.1:19561"        # alpha node
DCR_ALPHA_WALLET_HOST="127.0.0.1:19562" # alpha wallet
DCR_TRADING1_HOST="127.0.0.1:19581"   # trading1 wallet (used by the plugin)
DCR_RPC_USER="user"
DCR_RPC_PASS="pass"
ALPHA_CERT="$HOME/dextest/dcr/alpha/rpc.cert"
TRADING1_CERT="$HOME/dextest/dcr/trading1/rpc.cert"

# PostgreSQL
BTCPAY_DB="btcpaytest"
BTCPAY_USER="btcpay"
BTCPAY_PASS="btcpay"

# tmux sessions
HARNESS_SESSION="dcr-harness"
E2E_SESSION="dcr-e2e"

OS="$(uname)"
ARCH_RAW="$(uname -m)"

########################################
# Helpers
########################################

log_ok()   { echo -e "[${GREEN}✔${NC}] $1"; }
log_info() { echo -e "[${BLUE}→${NC}] $1"; }
log_warn() { echo -e "[${YELLOW}!${NC}] $1"; }
fail()     { echo -e "[${RED}✖${NC}] $1"; exit 1; }

section() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════${NC}"
  echo ""
}

pause() {
  echo ""
  echo -e "[${YELLOW}?${NC}] $1"
  read -rp "    Press Enter to continue..."
  echo ""
}

lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }

# Map uname arch to Decred release arch
dcr_arch() {
  case "$ARCH_RAW" in
    x86_64)           echo "amd64" ;;
    arm64|aarch64)    echo "arm64" ;;
    *) fail "Unsupported architecture: $ARCH_RAW" ;;
  esac
}

# Add the downloaded Decred binaries directory to PATH if it exists and isn't
# already there. Called unconditionally at startup so standalone commands like
# 'test', 'test-pay', 'test-send' find dcrctl without running 'binaries' first.
restore_dcr_path() {
  local dcr_os dcr_arch_val extract_dir
  dcr_os="$(lower "$OS")"
  dcr_arch_val="$(dcr_arch 2>/dev/null)" || return 0
  extract_dir="$BIN_DIR/decred-${dcr_os}-${dcr_arch_val}-${DCR_VERSION}"
  if [[ -d "$extract_dir" ]] && [[ ":$PATH:" != *":$extract_dir:"* ]]; then
    export PATH="$extract_dir:$PATH"
  fi
}
restore_dcr_path

########################################
# PostgreSQL helper — works on macOS and Linux
########################################

run_psql() {
  # Prefer peer auth via the postgres OS user (standard Linux server install).
  # Fall back to TCP as the current user when the postgres system user is absent
  # (macOS Homebrew, WSL with only the psql client installed, etc.).
  if id postgres >/dev/null 2>&1; then
    sudo -u postgres psql "$@"
  else
    psql -U postgres "$@"
  fi
}

########################################
# dcrctl wrappers
########################################

dcrctl_alpha_node() {
  dcrctl --simnet -s "$DCR_NODE_HOST" \
    -u "$DCR_RPC_USER" -P "$DCR_RPC_PASS" \
    -c "$ALPHA_CERT" "$@"
}

dcrctl_alpha_wallet() {
  dcrctl --simnet -s "$DCR_ALPHA_WALLET_HOST" \
    -u "$DCR_RPC_USER" -P "$DCR_RPC_PASS" \
    -c "$ALPHA_CERT" --wallet "$@"
}

dcrctl_trading1() {
  dcrctl --simnet -s "$DCR_TRADING1_HOST" \
    -u "$DCR_RPC_USER" -P "$DCR_RPC_PASS" \
    -c "$TRADING1_CERT" --wallet "$@"
}

########################################
# Phase 1 — System dependencies
########################################

install_brew_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    log_info "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  log_ok "Homebrew ready...next!"
}

pkg_install() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    log_ok "$cmd already installed...next!"
    return
  fi
  log_info "Installing $pkg..."
  if [[ "$OS" == "Darwin" ]]; then
    brew install "$pkg"
  else
    sudo apt-get update -qq
    sudo apt-get install -y "$pkg"
  fi
  log_ok "$cmd installed...next!"
}

install_dotnet() {
  if command -v dotnet >/dev/null 2>&1; then
    log_ok ".NET $(dotnet --version) already installed...next!"
    return
  fi
  log_info "Installing .NET 10 SDK..."
  if [[ "$OS" == "Darwin" ]]; then
    brew install dotnet-sdk
  else
    sudo apt-get update -qq
    sudo apt-get install -y dotnet-sdk-10.0 dotnet-runtime-10.0 dotnet-host-10.0
  fi
  log_ok ".NET $(dotnet --version) installed...next!"
}

pg_start_service() {
  if [[ "$OS" == "Darwin" ]]; then
    brew services start postgresql@15 2>/dev/null || true
  elif command -v systemctl >/dev/null 2>&1 && \
       systemctl list-units --type=service 2>/dev/null | grep -q postgresql; then
    sudo systemctl enable postgresql 2>/dev/null || true
    sudo systemctl start  postgresql 2>/dev/null || true
  else
    # WSL or systems without systemd — fall back to sysvinit service wrapper
    sudo service postgresql start 2>/dev/null || true
  fi
}

install_postgresql() {
  # Check for the server, not just the psql client — the client can be
  # installed without the server (which is what creates the postgres OS user).
  local need_install=false
  if ! command -v psql >/dev/null 2>&1; then
    need_install=true
  elif ! id postgres >/dev/null 2>&1; then
    # Client present but no postgres OS user → server not installed
    need_install=true
  fi

  if $need_install; then
    log_info "Installing PostgreSQL server..."
    if [[ "$OS" == "Darwin" ]]; then
      brew install postgresql@15
      export PATH="$(brew --prefix)/opt/postgresql@15/bin:$PATH"
    else
      sudo apt-get update -qq
      sudo apt-get install -y postgresql postgresql-contrib
    fi
    log_ok "PostgreSQL installed...next!"
  else
    log_ok "PostgreSQL already installed...next!"
  fi

  pg_start_service

  # Verify we can actually talk to the server
  if ! run_psql -c "\q" >/dev/null 2>&1; then
    fail "Cannot connect to PostgreSQL. Make sure the server is running and accessible."
  fi
}

install_system_deps() {
  section "Phase 1: System Dependencies"

  if [[ "$OS" == "Darwin" ]]; then
    install_brew_macos
  fi

  pkg_install git  git
  pkg_install curl curl
  pkg_install tmux tmux
  pkg_install jq   jq

  install_dotnet
  install_postgresql

  log_ok "All system dependencies ready...next!"
}

########################################
# Phase 2 — Decred binaries
#   Downloads pre-built release binaries.
#   Falls back to building from source with Go if a Go toolchain is present.
########################################

install_decred_binaries() {
  section "Phase 2: Decred Binaries"

  if command -v dcrd >/dev/null 2>&1 && \
     command -v dcrwallet >/dev/null 2>&1 && \
     command -v dcrctl >/dev/null 2>&1; then
    log_ok "dcrd, dcrwallet, dcrctl already in PATH...skipping!"
    return
  fi

  # Prefer pre-built release archives (no Go toolchain required)
  mkdir -p "$BIN_DIR"
  local dcr_os
  dcr_os="$(lower "$OS")"
  local dcr_arch
  dcr_arch="$(dcr_arch)"
  local archive="decred-${dcr_os}-${dcr_arch}-${DCR_VERSION}.tar.gz"
  local extract_dir="$BIN_DIR/decred-${dcr_os}-${dcr_arch}-${DCR_VERSION}"

  if [[ ! -d "$extract_dir" ]]; then
    log_info "Downloading Decred ${DCR_VERSION} release binaries..."
    curl -fsSL \
      "https://github.com/decred/decred-binaries/releases/download/${DCR_VERSION}/${archive}" \
      -o "$BIN_DIR/$archive"
    tar -xzf "$BIN_DIR/$archive" -C "$BIN_DIR"
    rm -f "$BIN_DIR/$archive"
    log_ok "Decred binaries extracted to $extract_dir...next!"
  else
    log_ok "Decred binaries already downloaded...next!"
  fi

  export PATH="$extract_dir:$PATH"

  # Persist PATH addition to the user's shell profile
  local profile_file
  case "$(basename "$SHELL")" in
    zsh)  profile_file="$HOME/.zshrc" ;;
    bash) profile_file="$HOME/.bashrc" ;;
    *)    profile_file="$HOME/.profile" ;;
  esac

  if ! grep -q "btcpay-dcr-e2e/bin" "$profile_file" 2>/dev/null; then
    echo "" >> "$profile_file"
    echo "# Added by e2etest.sh" >> "$profile_file"
    echo "export PATH=\"$extract_dir:\$PATH\"" >> "$profile_file"
    log_ok "PATH updated in $profile_file...next!"
  fi

  # Verify
  for bin in dcrd dcrwallet dcrctl; do
    command -v "$bin" >/dev/null 2>&1 || fail "$bin not found after install — check $extract_dir"
  done

  log_ok "dcrd, dcrwallet, dcrctl ready...next!"
}

########################################
# Phase 3 — dcrdex simnet harness
########################################

start_harness() {
  section "Phase 3: Simnet Harness"

  mkdir -p "$ROOT"

  if [[ ! -d "$DCRDEX_DIR" ]]; then
    log_info "Cloning dcrdex..."
    git clone https://github.com/decred/dcrdex "$DCRDEX_DIR"
    log_ok "dcrdex cloned...next!"
  else
    log_ok "dcrdex already cloned...next!"
  fi

  if tmux has-session -t "$HARNESS_SESSION" 2>/dev/null; then
    log_ok "Harness session '$HARNESS_SESSION' already running...next!"
  else
    log_info "Starting dcr harness (it will create its own '$HARNESS_SESSION' tmux session)..."
    # harness.sh calls `tmux new-session -s dcr-harness` internally, so we must
    # NOT pre-create that session. We open a window in our own E2E_SESSION and
    # clear TMUX so harness.sh can create its session without a name collision.
    if ! tmux has-session -t "$E2E_SESSION" 2>/dev/null; then
      tmux new-session -d -s "$E2E_SESSION" -n main "bash"
    fi
    tmux new-window -t "$E2E_SESSION" -n harness \
      "export PATH='$PATH'; cd $DCRDEX_DIR/dex/testing/dcr && TMUX= bash harness.sh || bash"
    log_ok "Harness script launched...next!"
  fi

  log_info "Waiting for harness to be ready (up to 120s)..."
  local elapsed=0
  until dcrctl_alpha_node getblockcount >/dev/null 2>&1; do
    if (( elapsed >= 120 )); then
      fail "Harness not ready after ${elapsed}s. Attach with: tmux attach -t $HARNESS_SESSION"
    fi
    sleep 5
    (( elapsed += 5 )) || true
    log_info "Still waiting... (${elapsed}s)"
  done

  log_ok "Harness ready — block count: $(dcrctl_alpha_node getblockcount)...next!"
}

########################################
# Phase 4 — Clone and build the plugin
########################################

setup_plugin() {
  section "Phase 4: Plugin Build"

  mkdir -p "$ROOT"

  if [[ ! -d "$PLUGIN_DIR" ]]; then
    local repo_url="${PLUGIN_REPO_URL:-}"
    if [[ -z "$repo_url" ]]; then
      echo ""
      read -rp "  Plugin Git URL [${DEFAULT_PLUGIN_REPO_URL}]: " repo_url
      repo_url="${repo_url:-$DEFAULT_PLUGIN_REPO_URL}"
    fi
    [[ -z "$repo_url" ]] && fail "No plugin repository URL provided."

    log_info "Cloning plugin..."
    git clone --recursive "$repo_url" "$PLUGIN_DIR"
    log_ok "Plugin cloned...next!"
  else
    log_ok "Plugin directory exists — updating submodules..."
    cd "$PLUGIN_DIR"
    git submodule update --init --recursive
  fi

  cd "$PLUGIN_DIR"

  # NETSDK1226 workaround required by some .NET 10 SDK versions
  local props="submodules/btcpayserver/Directory.Build.props"
  if [[ ! -f "$props" ]]; then
    log_info "Applying NETSDK1226 workaround..."
    echo '<Project><PropertyGroup><AllowMissingPrunePackageData>true</AllowMissingPrunePackageData></PropertyGroup></Project>' \
      > "$props"
    log_ok "Workaround applied...next!"
  fi

  log_info "Building plugin..."
  dotnet build Plugins/Decred/BTCPayServer.Plugins.Decred.csproj
  log_ok "Plugin built successfully...next!"
}

########################################
# Phase 5 — RPC integration tests (optional sanity check)
########################################

run_integration_tests() {
  section "Phase 5: RPC Integration Tests"

  [[ ! -d "$PLUGIN_DIR" ]] && fail "Plugin not found at $PLUGIN_DIR. Run 'plugin' phase first."
  cd "$PLUGIN_DIR"

  log_info "Running HarnessTest (harness must be running)..."
  dotnet run --project Tests/HarnessTest.csproj
  log_ok "All integration tests passed...next!"
}

########################################
# Phase 6 — PostgreSQL DB setup
########################################

setup_postgres() {
  section "Phase 6: PostgreSQL"

  # Create role if missing
  if ! run_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$BTCPAY_USER'" 2>/dev/null | grep -q 1; then
    log_info "Creating PostgreSQL user '$BTCPAY_USER'..."
    run_psql -c "CREATE USER $BTCPAY_USER WITH PASSWORD '$BTCPAY_PASS';"
    log_ok "User created...next!"
  else
    log_ok "User '$BTCPAY_USER' already exists...next!"
  fi

  # Create database if missing
  if ! run_psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$BTCPAY_DB"; then
    log_info "Creating database '$BTCPAY_DB'..."
    run_psql -c "CREATE DATABASE $BTCPAY_DB;"
    run_psql -c "GRANT ALL ON DATABASE $BTCPAY_DB TO $BTCPAY_USER;"
    run_psql -c "ALTER DATABASE $BTCPAY_DB OWNER TO $BTCPAY_USER;"
    log_ok "Database created...next!"
  else
    log_ok "Database '$BTCPAY_DB' already exists...next!"
  fi

  run_psql -d "$BTCPAY_DB" -c "GRANT ALL ON SCHEMA public TO $BTCPAY_USER;" 2>/dev/null || true

  log_ok "PostgreSQL ready...next!"
}

########################################
# Phase 7 — Install plugin DLL + BTCPayServer
########################################

install_plugin_dll() {
  [[ ! -d "$PLUGIN_DIR" ]] && fail "Plugin not found at $PLUGIN_DIR. Run 'plugin' phase first."
  cd "$PLUGIN_DIR"

  log_info "Building plugin (Debug)..."
  dotnet build Plugins/Decred/BTCPayServer.Plugins.Decred.csproj -c Debug
  log_ok "Plugin built...next!"

  log_info "Installing plugin DLL into $PLUGIN_INSTALL_DIR..."
  mkdir -p "$PLUGIN_INSTALL_DIR"
  cp Plugins/Decred/bin/Debug/net10.0/* "$PLUGIN_INSTALL_DIR/"
  log_ok "Plugin DLL installed...next!"
}

write_btcpay_launcher() {
  # Write env vars + dotnet run to a temp script so tmux never has to deal
  # with nested quoting inside a command string.
  local launcher
  launcher="$(mktemp /tmp/btcpay-launch-XXXXXX.sh)"
  cat > "$launcher" <<LAUNCHER
#!/usr/bin/env bash
export PATH="$PATH"
export BTCPAY_DCR_WALLET_URI="https://$DCR_TRADING1_HOST"
export BTCPAY_DCR_RPC_USERNAME="$DCR_RPC_USER"
export BTCPAY_DCR_RPC_PASSWORD="$DCR_RPC_PASS"
export BTCPAY_POSTGRES="Host=localhost;Database=$BTCPAY_DB;Username=$BTCPAY_USER;Password=$BTCPAY_PASS"
export BTCPAY_NETWORK="regtest"
export BTCPAY_DEBUGLOG="debug.log"
cd "$PLUGIN_DIR"
exec dotnet run --no-launch-profile \\
  --project submodules/btcpayserver/BTCPayServer/BTCPayServer.csproj
LAUNCHER
  chmod +x "$launcher"
  echo "$launcher"
}

# Start BTCPayServer in a tmux window (non-blocking)
start_btcpay_tmux() {
  section "Phase 7: BTCPayServer (tmux)"

  install_plugin_dll

  # Ensure the session exists — start_harness may have already created it
  if ! tmux has-session -t "$E2E_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$E2E_SESSION" -n main "bash"
  fi

  # Check for the btcpay *window* specifically, not just the session
  if tmux list-windows -t "$E2E_SESSION" -F "#{window_name}" 2>/dev/null | grep -qx "btcpay"; then
    log_warn "BTCPayServer window already running in '$E2E_SESSION'...next!"
  else
    local launcher
    launcher="$(write_btcpay_launcher)"
    tmux new-window -t "$E2E_SESSION" -n btcpay "bash $launcher; bash"
    log_ok "BTCPayServer started in '$E2E_SESSION':btcpay...next!"
  fi

  log_info "Waiting for BTCPayServer at http://localhost:23002 (up to 180s)..."
  local elapsed=0
  until curl -sf http://localhost:23002 >/dev/null 2>&1; do
    if (( elapsed >= 180 )); then
      fail "BTCPayServer not reachable after ${elapsed}s. Check: tmux attach -t $E2E_SESSION"
    fi
    sleep 5
    (( elapsed += 5 )) || true
    log_info "Still waiting... (${elapsed}s)"
  done

  log_ok "BTCPayServer is up at http://localhost:23002...next!"
}

# Start BTCPayServer in the foreground (blocking — for watching logs)
start_btcpay_fg() {
  section "Phase 7: BTCPayServer (foreground)"

  install_plugin_dll

  log_info "Launching BTCPayServer at http://localhost:23002..."
  log_info "Confirm plugin loaded by looking for:"
  log_info "  'Running plugin BTCPayServer.Plugins.Decred - 1.0.0.0'"
  log_info "  'Supported chains: BTC,DCR'"
  log_info "  'DCR daemon availability changed to True'"
  echo ""
  log_warn "Press Ctrl+C to stop."
  echo ""

  export BTCPAY_DCR_WALLET_URI="https://$DCR_TRADING1_HOST"
  export BTCPAY_DCR_RPC_USERNAME="$DCR_RPC_USER"
  export BTCPAY_DCR_RPC_PASSWORD="$DCR_RPC_PASS"
  export BTCPAY_POSTGRES="Host=localhost;Database=$BTCPAY_DB;Username=$BTCPAY_USER;Password=$BTCPAY_PASS"
  export BTCPAY_NETWORK="regtest"
  export BTCPAY_DEBUGLOG="debug.log"

  cd "$PLUGIN_DIR"
  dotnet run --no-launch-profile \
    --project submodules/btcpayserver/BTCPayServer/BTCPayServer.csproj
}

########################################
# Phase 8 — Browser setup guide
########################################

browser_setup_guide() {
  section "Phase 8: BTCPayServer Configuration"

  echo "  Follow these steps in your browser:"
  echo ""
  echo "  1. Open http://localhost:23002"
  echo "  2. Create an admin account"
  echo "  3. Create a store"
  echo "  4. In the store, go to Settings"
  echo "  5. Click 'Decred' in the left sidebar"
  echo "     (URL pattern: /stores/<id>/decredlike/DCR)"
  echo "  6. Check 'Enable DCR payments' and click Save"
  echo ""
  echo "  Both status indicators on that page should read 'Available':"
  echo "    Daemon:  Available"
  echo "    Wallet:  Available"
  echo ""
  pause "Complete the browser setup, then press Enter to run the payment test."
}

########################################
# Phase 9 — Payment test
########################################

test_payment() {
  section "Phase 9: Payment Test"

  echo "  Steps in BTCPayServer:"
  echo "  1. Go to Invoices > Create Invoice"
  echo "  2. Set currency to DCR and choose an amount"
  echo "  3. Create the invoice"
  echo "  4. Copy the Decred payment address (starts with 'Ss' on simnet)"
  echo ""

  read -rp "  Paste the DCR payment address from the invoice: " DCR_INVOICE_ADDR
  [[ -z "$DCR_INVOICE_ADDR" ]] && fail "No address provided."

  local amount
  read -rp "  Amount to send in DCR [1.0]: " amount
  amount="${amount:-1.0}"

  log_info "Sending $amount DCR from alpha wallet to $DCR_INVOICE_ADDR..."
  local txid
  txid=$(dcrctl_alpha_wallet sendtoaddress "$DCR_INVOICE_ADDR" "$amount")
  log_ok "Transaction sent ($amount DCR): $txid"

  log_info "Mining a block to confirm..."
  cd "$HARNESS_CTL_DIR" && ./mine-alpha 1
  log_ok "Block mined...next!"

  echo ""
  log_ok "Payment of $amount DCR sent and confirmed!"
  log_info "The invoice poller runs every 15s — give it a moment, then check BTCPayServer."
  log_info "You can also trigger an immediate check:"
  echo "    curl 'http://localhost:23002/DecredLikeDaemonCallback/block?cryptoCode=DCR&hash=test'"
  echo ""
  pause "Verify the invoice shows 'Settled' in BTCPayServer, then press Enter."
}

########################################
# Phase 10 — Send test
########################################

test_send() {
  section "Phase 10: Send Test"

  log_info "Getting a new address from trading1 wallet to fund from alpha..."
  local trading1_addr
  trading1_addr=$(dcrctl_trading1 getnewaddress)
  log_ok "trading1 address: $trading1_addr"

  log_info "Sending 10 DCR from alpha to trading1..."
  dcrctl_alpha_wallet sendtoaddress "$trading1_addr" 10.0
  log_ok "Funds sent...next!"

  log_info "Mining a block to confirm..."
  cd "$HARNESS_CTL_DIR" && ./mine-alpha 1
  log_ok "Block mined...next!"

  log_info "Generating a destination address from the alpha wallet..."
  local alpha_dest
  alpha_dest=$(dcrctl_alpha_wallet getnewaddress)
  log_ok "Destination address: $alpha_dest"

  echo ""
  echo "  In BTCPayServer (store Settings > Decred > Send):"
  echo "    Destination: $alpha_dest"
  echo "    Amount:      1 DCR (or any amount below your balance)"
  echo "    Click 'Send Transaction'"
  echo ""
  echo "  A success message with a transaction ID should appear."
  echo ""
  pause "After the transaction is sent in the browser, press Enter to mine a confirming block."

  log_info "Mining a block to confirm the send transaction..."
  cd "$HARNESS_CTL_DIR" && ./mine-alpha 1
  log_ok "Block mined — transaction confirmed...next!"

  log_ok "Send test complete...next!"
}

########################################
# Session teardown
########################################

stop_sessions() {
  log_info "Stopping BTCPayServer and harness tmux sessions..."

  # Stop BTCPayServer gracefully (Ctrl-C), give it a moment to shut down
  if tmux has-session -t "$E2E_SESSION" 2>/dev/null; then
    if tmux list-windows -t "$E2E_SESSION" -F "#{window_name}" 2>/dev/null | grep -qx "btcpay"; then
      log_info "Sending Ctrl-C to BTCPayServer..."
      tmux send-keys -t "$E2E_SESSION:btcpay" C-c
      sleep 3
    fi
    tmux kill-session -t "$E2E_SESSION"
    log_ok "Session '$E2E_SESSION' stopped...next!"
  else
    log_ok "Session '$E2E_SESSION' not running...next!"
  fi

  # Stop the dcrdex harness
  if tmux has-session -t "$HARNESS_SESSION" 2>/dev/null; then
    local ctl="$HARNESS_CTL_DIR/quit"
    if [[ -x "$ctl" ]]; then
      log_info "Running harness quit script..."
      bash "$ctl" 2>/dev/null || true
      sleep 2
    fi
    tmux kill-session -t "$HARNESS_SESSION"
    log_ok "Session '$HARNESS_SESSION' stopped...next!"
  else
    log_ok "Session '$HARNESS_SESSION' not running...next!"
  fi
}

########################################
# Reset — stop sessions, wipe DB + plugin state, rebuild
########################################

drop_db() {
  if run_psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw "$BTCPAY_DB"; then
    log_info "Terminating active connections to '$BTCPAY_DB'..."
    run_psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$BTCPAY_DB' AND pid <> pg_backend_pid();" >/dev/null
    log_info "Dropping database '$BTCPAY_DB'..."
    run_psql -c "DROP DATABASE $BTCPAY_DB;"
  fi
  run_psql -c "CREATE DATABASE $BTCPAY_DB;"
  run_psql -c "GRANT ALL ON DATABASE $BTCPAY_DB TO $BTCPAY_USER;"
  run_psql -c "ALTER DATABASE $BTCPAY_DB OWNER TO $BTCPAY_USER;"
  run_psql -d "$BTCPAY_DB" -c "GRANT ALL ON SCHEMA public TO $BTCPAY_USER;" 2>/dev/null || true
  log_ok "Database reset...next!"
}

reset_all() {
  section "Reset"

  log_warn "This will stop all sessions, drop database '$BTCPAY_DB', and clear plugin state."
  read -rp "  Are you sure? [y/N] " confirm
  [[ "${confirm,,}" != "y" ]] && { log_info "Aborted."; exit 0; }

  stop_sessions
  drop_db

  rm -rf "$PLUGIN_INSTALL_DIR"
  rm -f  "$HOME/.btcpayserver/Plugins/commands"
  log_ok "Plugin state cleared...next!"

  if [[ -d "$PLUGIN_DIR" ]]; then
    log_info "Rebuilding and reinstalling plugin..."
    cd "$PLUGIN_DIR"
    dotnet build Plugins/Decred/BTCPayServer.Plugins.Decred.csproj -c Debug
    mkdir -p "$PLUGIN_INSTALL_DIR"
    cp Plugins/Decred/bin/Debug/net10.0/* "$PLUGIN_INSTALL_DIR/"
    log_ok "Plugin reinstalled...next!"
  fi

  log_ok "Reset complete. Run: $0 run"
}

########################################
# Clean — remove everything the script installed
########################################

clean_all() {
  section "Clean"

  log_warn "This will remove ALL installed state:"
  log_warn "  tmux sessions, PostgreSQL DB + user, plugin DLL, cloned repos ($ROOT), Decred binaries"
  read -rp "  Are you sure? [y/N] " confirm
  [[ "${confirm,,}" != "y" ]] && { log_info "Aborted."; exit 0; }

  # 1. Stop sessions first (reset handles this too, but clean is standalone)
  stop_sessions

  # 2. Drop DB and PostgreSQL user
  drop_db
  if run_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$BTCPAY_USER'" 2>/dev/null | grep -q 1; then
    log_info "Dropping PostgreSQL user '$BTCPAY_USER'..."
    run_psql -c "DROP USER $BTCPAY_USER;" 2>/dev/null || true
    log_ok "PostgreSQL user removed...next!"
  fi

  # 3. Plugin install dir + BTCPayServer plugin state
  rm -rf "$PLUGIN_INSTALL_DIR"
  rm -f  "$HOME/.btcpayserver/Plugins/commands"
  log_ok "Plugin state cleared...next!"

  # 4. Cloned repos
  if [[ -d "$ROOT" ]]; then
    log_info "Removing cloned repos at $ROOT..."
    rm -rf "$ROOT"
    log_ok "Repos removed...next!"
  fi

  # 5. Decred binaries (only those downloaded by this script into BIN_DIR)
  if [[ -d "$BIN_DIR" ]]; then
    log_info "Removing downloaded Decred binaries at $BIN_DIR..."
    rm -rf "$BIN_DIR"
    log_ok "Binaries removed...next!"
  fi

  log_ok "Clean complete."
}

########################################
# Usage
########################################

usage() {
  echo ""
  echo "Usage: $0 [command]"
  echo ""
  echo "  Default (no args): same as 'all'"
  echo ""
  echo "Commands:"
  echo "  all         One-click: install deps, build binaries, start harness, build"
  echo "              plugin, set up postgres, start BTCPayServer (tmux),"
  echo "              then run the interactive payment + send tests"
  echo ""
  echo "  setup       Phases 1-6: install + build everything without starting"
  echo "              BTCPayServer or running interactive tests"
  echo "  run         Phase 7b: install plugin and start BTCPayServer in the"
  echo "              foreground so you can watch logs"
  echo "  test        Phases 9-10: payment test + send test (BTCPayServer must"
  echo "              already be running)"
  echo ""
  echo "  Individual phases:"
  echo "  deps        Phase 1 — install system dependencies"
  echo "  binaries    Phase 2 — download/install Decred binaries"
  echo "  harness     Phase 3 — clone dcrdex and start simnet harness"
  echo "  plugin      Phase 4 — clone and build the BTCPay Decred plugin"
  echo "  test-rpc    Phase 5 — run RPC integration tests (harness must be up)"
  echo "  postgres    Phase 6 — create PostgreSQL user and database"
  echo "  guide       Phase 8 — print browser configuration instructions"
  echo "  test-pay    Phase 9 — send DCR to an invoice and verify settlement"
  echo "  test-send   Phase 10 — fund trading1 and test the BTCPay send UI"
  echo ""
  echo "  stop        Stop BTCPayServer and harness tmux sessions cleanly"
  echo "  reset       Stop sessions, drop DB + clear plugin state, rebuild"
  echo "  clean       Remove everything: sessions, DB, plugin, repos, binaries"
  echo ""
  echo "Environment variables:"
  echo "  PLUGIN_REPO_URL   Git URL of the plugin repo (default: $DEFAULT_PLUGIN_REPO_URL)"
  echo "  E2E_ROOT          Working directory for cloned repos (default: ~/btcpay-dcr-e2e)"
  echo "  DCR_VERSION       Decred release to download (default: $DCR_VERSION)"
  echo ""
}

########################################
# Entry point
########################################

CMD="${1:-all}"

case "$CMD" in
  all)
    install_system_deps
    install_decred_binaries
    start_harness
    setup_plugin
    setup_postgres
    start_btcpay_tmux
    browser_setup_guide
    test_payment
    test_send
    ;;
  setup)
    install_system_deps
    install_decred_binaries
    start_harness
    setup_plugin
    setup_postgres
    log_ok "Setup complete. Run: $0 run"
    ;;
  run)
    start_btcpay_fg
    ;;
  test)
    test_payment
    test_send
    ;;
  deps)      install_system_deps ;;
  binaries)  install_decred_binaries ;;
  harness)   start_harness ;;
  plugin)    setup_plugin ;;
  test-rpc)  run_integration_tests ;;
  postgres)  setup_postgres ;;
  guide)     browser_setup_guide ;;
  test-pay)  test_payment ;;
  test-send) test_send ;;
  stop)      stop_sessions ;;
  reset)     reset_all ;;
  clean)     clean_all ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo -e "[${RED}✖${NC}] Unknown command: $CMD"
    usage
    exit 1
    ;;
esac
