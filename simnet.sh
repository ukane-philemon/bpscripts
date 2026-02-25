#!/usr/bin/env bash
set -e

SESSION="nbx-harness"
DCR_DEX_TEST_DIR="$HOME/dextest/dcr/alpha"
ROOT="$HOME/nbtest"
DEX="$ROOT/dcrdex"
BIN_DIR="$HOME/crypto-bin"
NBX_CONFIG_DIR="$HOME/.nbxplorer/RegTest"
BTCPAY_CONFIG_DIR="$HOME/.btcpayserver/RegTest"
GREEN="\033[0;32m"

OS="$(uname)"

log_ok() {
  echo -e "[${GREEN}✔${NC}] $1"
}

########################################
# All Config & Data Dir
########################################

log_ok "Root DIR containing all repos -> $ROOT"
log_ok "DIR containing NBXplorer configs $NBX_CONFIG_DIR"
log_ok "DIR containing BTCPayServer configs $BTCPAY_CONFIG_DIR"
log_ok "Bin DIR containing all harness executables -> $BIN_DIR"

########################################
# PostgreSQL RegTest Setup
########################################

NBX_DB="nbxplorerdb"
NBX_USER="nbxplorerdbuser"
NBX_PASS="nbxplorerdbpass"

BTCPAY_DB="btcpaydb"
BTCPAY_USER="btcpaydbuser"
BTCPAY_PASS="btcpaypass"

########################################
# PostgreSQL Command Wrapper
########################################

if [[ "$OS" == "Darwin" ]]; then
  PSQL_CMD="psql -U postgres"
else
  PSQL_CMD="sudo -u postgres psql"
fi

run_psql() {
  $PSQL_CMD "$@"
}

if ! run_psql -c "\q" >/dev/null 2>&1; then
    createuser -s postgres
fi


create_role_if_missing() {
  local role=$1
  local pass=$2
  if ! run_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role'" | grep -q 1; then
    log_ok "Creating role $role..."
    run_psql -c "CREATE USER $role WITH ENCRYPTED PASSWORD '$pass';"
  else
    log_ok "Role $role exists...next!"
  fi
}

create_db_if_missing() {
  local db=$1
  local owner=$2
  if ! run_psql -lqt | cut -d \| -f1 | grep -qw "$db"; then
    log_ok  "Creating database $db..."
    run_psql -c \
      "CREATE DATABASE $db TEMPLATE template0 LC_CTYPE 'C' LC_COLLATE 'C' ENCODING 'UTF8';"
    run_psql -c "ALTER DATABASE $db OWNER TO $owner;"
  else
    log_ok "Database $db exists...next!"
  fi
}

create_role_if_missing "$NBX_USER" "$NBX_PASS"
create_db_if_missing "$NBX_DB" "$NBX_USER"

create_role_if_missing "$BTCPAY_USER" "$BTCPAY_PASS"
create_db_if_missing "$BTCPAY_DB" "$BTCPAY_USER"

run_psql -d "$NBX_DB" -c "GRANT ALL ON SCHEMA public TO $NBX_USER;"
run_psql -d "$BTCPAY_DB" -c "GRANT ALL ON SCHEMA public TO $BTCPAY_USER;"


mkdir -p "$NBX_CONFIG_DIR"

if [[ -f "$NBX_CONFIG_DIR/settings.config" ]]; then
 log_ok "Overwriting existing NBXplorer RegTest config..."
fi

cat > "$NBX_CONFIG_DIR/settings.config" <<EOF
noauth=1
postgres=User ID=$NBX_USER;Password=$NBX_PASS;Application Name=nbxplorer;MaxPoolSize=20;Host=localhost;Port=5432;Database=$NBX_DB;
btc.rpc.user=user
btc.rpc.password=pass
btc.rpc.url=http://127.0.0.1:20556
btc.node.endpoint=127.0.0.1:20575
dcr.rpc.user=user
dcr.rpc.password=pass
dcr.rpc.certfile=$DCR_DEX_TEST_DIR/rpc.cert
dcr.rpc.url=https://localhost:19562
dcr.node.endpoint=127.0.0.1:19560
EOF

log_ok "NBXplorer RegTest config written...next!"

mkdir -p "$BTCPAY_CONFIG_DIR"

if [[ -f "$BTCPAY_CONFIG_DIR/settings.config" ]]; then
 log_ok "Overwriting existing BTCPayServer RegTest config..."
fi

cat > "$BTCPAY_CONFIG_DIR/settings.config" <<EOF
postgres=User ID=$BTCPAY_USER;Password=$BTCPAY_PASS;Application Name=btcpayserver;Host=localhost;Port=5432;Database=$BTCPAY_DB;
explorer.postgres=User ID=$NBX_USER;Password=$NBX_PASS;Application Name=nbxplorer;MaxPoolSize=20;Host=localhost;Port=5432;Database=$NBX_DB;
EOF

log_ok "BTCPayServer RegTest config written...next!"

# Ensure existing sessions are exited.
./quit.sh

log_ok "Starting new $SESSION"

tmux new-session -d -s "$SESSION" -n bitcoin-harness \
  "cd $DEX/dex/testing/btc && TMUX= ./harness.sh || bash"

sleep 3
echo "[→] Waiting for Bitcoin harness..."
tmux wait-for btc
echo "[✔] Bitcoin ready...next!" 

tmux new-window -t "$SESSION" -n decred-harness \
  "cd $DEX/dex/testing/dcr && TMUX= ./harness.sh || bash"

sleep 3
echo "[→] Waiting for Decred harness..."
tmux wait-for donedcr
echo "[✔] Decred ready...next!"

sleep 3

tmux new-window -t "$SESSION" -n nbxplorer \
  "cd $HOME/nbtest/NBXplorer && ./run.sh --network=regtest --chains=btc,dcr || bash"

tmux new-window -t "$SESSION" -n btcpay \
  "cd $HOME/nbtest/btcpayserver && ./run.sh --network=regtest --chains=btc,dcr || bash"

tmux new-window -t "$SESSION" -n main
tmux send-keys -t "$SESSION:main" \
  "clear && echo 'BTCPay ready at http://127.0.0.1:23002/....'" C-m

log_ok "tmux sessions created successfully..."

tmux attach -t $SESSION