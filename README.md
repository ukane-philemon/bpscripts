# Decred Plugin — End-to-End Test

Tests the [BTCPay Server Decred plugin](https://github.com/bisoncraft/btcpayserver-decred-plugin) against a local simnet. No prior installs required.

## Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ukane-philemon/bpscripts/master/e2etest.sh)
```

Installs all dependencies, starts the Decred simnet harness, builds the plugin, and launches BTCPay Server. Then walks you through a payment test and a send test interactively.

Already cloned? Run directly:

```bash
cd ~/bpscripts && ./e2etest.sh
```

Set `PLUGIN_REPO_URL` to test a different fork:

```bash
PLUGIN_REPO_URL=https://github.com/<you>/btcpayserver-decred-plugin ./e2etest.sh
```

## Key commands

| Command | What it does |
|---|---|
| `./e2etest.sh` | Full end-to-end run (default) |
| `./e2etest.sh setup` | Install + build everything without starting BTCPay Server |
| `./e2etest.sh run` | Start BTCPay Server in the foreground (watch logs) |
| `./e2etest.sh test` | Re-run the payment and send tests against a running server |
| `./e2etest.sh reset` | Stop sessions, drop DB, clear plugin state, rebuild |
| `./e2etest.sh clean` | Remove everything: sessions, DB, repos, binaries |

## BTCPay Server URL

```
http://localhost:23002
```

---

# BTCPay Server for Decred — One-Click Setup

Installs and runs BTCPay Server with Decred support (Regnet ready, Mainnet/Testnet compatible). You should also confirm that `DCR_VERSION` and `BTC_VERSION` are the latest version, update them in `install.sh` if not.

Check latest version for DCR at https://github.com/decred/decred-binaries/releases/latest/ and https://github.com/bitcoin/bitcoin/releases/latest for BTC. 

## 🚀 Install

Run (Supports macOS and Ubuntu/Debian Linux):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ukane-philemon/bpscripts/master/setup.sh)
```

This will:

1. Install required system tools
2. Install Git (if missing)
3. Install PostgreSQL + .NET
4. Install Decred & Bitcoin binaries
5. Start the nbx harness

## 🌐 Open BTCPay

After setup completes:

```
http://127.0.0.1:23002/
```

## 🔁 Restart Later

```bash
cd ~/bpscripts
./simnet.sh
```

## 🛑 Stop

Inside tmux main window, you can navigate there with `Ctrl+b` followed by number `4`:

```bash
./quit.sh
```

## 🔄 Update

```bash
cd ~/bpscripts
./setup.sh
```

## Note

If things aren't looking right, you may need to look at the node windows to
see errors. In tmux, you can navigate between windows by typing `Ctrl+b` and
then the window number. The window numbers are listed at the bottom
of the tmux window. `Ctrl+b` followed by the number `0`, for example, will
change to the alpha node window. Examining the node output to look for errors
is usually a good first debugging step.

# Cleanup

Folders you should delete in your root dir(`cd ~`) include:

`rm -rf ~/dextest ~/.nbxplorer ~/nbtest ~/.btcpayserver ~/crypto-bin ~/.dotnet`

If you're removing dotnet:

For MacOS: `brew uninstall dotnet-sdk tmux git curl postgresql@15 postgresql-contrib postgresql-client-common`
For Linux: `sudo apt remove --purge dotnet-sdk-10.0 dotnet-runtime-10.0 dotnet-host-10.0 tmux git curl postgresql postgresql-contrib postgresql-client-common`

You can remove tools you which to keep from the commands.

Remove updated path in `~/.bashrc` or `~/.zshrc` or `~/.profile`. You can edit the file using `nano filepath`.
