#!/bin/bash
# Generate the BeeGFS shared connection secret and distribute it to every node.
# Run this on the management node, before 04-configure-service.sh.
#
# BeeGFS refuses to start without this file. Every node must hold an identical
# copy, or services silently fail to authenticate to each other.
#
# The secret is generated on the cluster and is never written to this
# repository. Treat it like a private key.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/cluster.env"

AUTH=/etc/beegfs/conn.auth

# Union of every node list, deduplicated.
ALL_NODES="$(echo "$MGMT_NODES $META_NODES $STORAGE_NODES $CLIENT_NODES" \
  | tr ' ' '\n' | sort -u | tr '\n' ' ')"

if sudo test -f "$AUTH"; then
  echo "$AUTH already exists on $(hostname -s), reusing it"
else
  sudo dd if=/dev/random of="$AUTH" bs=128 count=1 status=none
  echo "generated $AUTH on $(hostname -s)"
fi

sudo chmod 400 "$AUTH"
sudo chown root:root "$AUTH"

# Push to the other nodes via a temp file, since scp cannot write to a
# root-owned path directly.
for h in $ALL_NODES; do
  [ "$h" = "$(hostname -s)" ] && continue
  sudo cat "$AUTH" | ssh -o BatchMode=yes "$h" \
    "cat > /tmp/conn.auth && sudo install -o root -g root -m 400 /tmp/conn.auth $AUTH && rm -f /tmp/conn.auth"
  echo "installed on $h"
done

echo "conn.auth present on: $ALL_NODES"
