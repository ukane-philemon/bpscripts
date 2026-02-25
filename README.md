## Setup BTC Pay Server

This one-click install script will ensure you have `brew` installed for macOS or `apt` for Linux. You should also confirm that `DCR_VERSION` and `BTC_VERSION` are the latest version, update them in `install.sh` if not.

Check latest version for DCR at https://github.com/decred/decred-binaries/releases/latest/ and https://github.com/bitcoin/bitcoin/releases/latest for BTC. 

1. Run `PG_VERSION=15 ./setup.sh` Or `PG_VERSION=16 ./setup.sh`.
2. Run `./quit.sh` in the `main` tmux window to exit all running programs. You can navigate there with `Ctrl+b` followed by number `4`.

If you quit the `nbx-harness` and intend to start again, just run `./simnet.sh` and do step 4 again to quit.

If you want to build after and upstream update, use `./setup.sh`. Exiting tools/resources will be skipped.

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