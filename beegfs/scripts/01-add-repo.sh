#!/bin/bash
# Add the BeeGFS 8.4 apt repository. Non-destructive; revert by deleting the
# two files this creates.
set -euo pipefail

KEYRING=/etc/apt/keyrings/beegfs.gpg
LIST=/etc/apt/sources.list.d/beegfs.list
REPO="https://www.beegfs.io/release/beegfs_8.4"
KEYURL="https://www.beegfs.io/release/latest-stable/gpg/GPG-KEY-beegfs"

sudo install -d -m 0755 /etc/apt/keyrings
curl -sSL --max-time 30 "$KEYURL" | sudo gpg --dearmor --yes -o "$KEYRING"
echo "deb [signed-by=$KEYRING] $REPO resolute non-free" | sudo tee "$LIST" >/dev/null

# Refresh only this repo so we do not disturb the rest of apt state.
sudo apt-get update -qq \
  -o Dir::Etc::sourcelist="$LIST" \
  -o Dir::Etc::sourceparts=- \
  -o APT::Get::List-Cleanup=0

echo "$(hostname): $(apt-cache policy beegfs-mgmtd | awk '/Candidate:/{print $2}')"
