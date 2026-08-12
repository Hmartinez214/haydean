#!/bin/bash
# Copy the NFS-exported shared directory onto BeeGFS.
#
#   usage: 05-migrate-data.sh <source-dir> [--final]
#
# Non-destructive. The source is never modified, so this can run while the
# cluster is live and be re-run to catch up changes. Run it once well before
# the maintenance window, then again with --final immediately before cutover
# to sync the delta.
#
# --final adds --delete so the destination exactly matches the source.
#
# Run this on the node that holds the source directory locally, so the read
# side is local disk and only the write side crosses the network.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/cluster.env"

SRC="${1:?usage: $0 <source-dir> [--final]}"
FINAL="${2:-}"

[ -d "$SRC" ] || { echo "$SRC does not exist on $(hostname -s)" >&2; exit 1; }
mountpoint -q "$BEEGFS_MOUNT" || { echo "$BEEGFS_MOUNT is not mounted" >&2; exit 1; }

DELETE=""
if [ "$FINAL" = "--final" ]; then
  DELETE="--delete"
  echo "final pass: destination will be made to match source exactly"
fi

# -aAX and --numeric-ids preserve ownership, permissions, ACLs and extended
# attributes. This is multi-user data, so getting that wrong is not recoverable
# by re-running.
sudo rsync -aAX --numeric-ids $DELETE --info=stats2 "$SRC/" "$BEEGFS_MOUNT/"

echo "source:      $(sudo du -sh "$SRC" | cut -f1)"
echo "destination: $(sudo du -sh "$BEEGFS_MOUNT" | cut -f1)"
