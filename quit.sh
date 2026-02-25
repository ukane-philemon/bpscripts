#!/usr/bin/env bash

SESSION="nbx-harness"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[→] No nbx-harness session running"
fi

echo "[→] Stopping BTCPay..."
tmux send-keys -t "$SESSION:btcpay" C-c

echo "[→] Stopping NBXplorer..."
tmux send-keys -t "$SESSION:nbxplorer" C-c

sleep 3

echo "[→] Stopping Bitcoin harness..."
tmux send-keys -t "$SESSION:bitcoin-harness" "./quit" C-m

echo "[→] Stopping Decred harness..."
tmux send-keys -t "$SESSION:decred-harness" "./quit" C-m

sleep 3

tmux kill-window -t "$SESSION:main"
tmux kill-session -t "$SESSION"
tmux kill-session -t "btc-harness" 2>/dev/null
tmux kill-session -t "dcr-harness" 2>/dev/null
sleep 2

echo "[✔] $SESSION session stopped cleanly"