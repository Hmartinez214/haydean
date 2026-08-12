#!/bin/bash
# Take an independent backup of a directory to another machine.
#
#   usage: 06-backup.sh <source-dir> <user@host> <remote-parent-dir> [ssh-key]
#
# Run this on the node that holds the source locally. The destination should
# be a machine that is NOT one of the BeeGFS storage nodes, so the backup
# survives the failure modes the filesystem itself does not cover.
#
# Non-destructive at both ends. Re-runnable: rsync only ships the delta.
set -euo pipefail

SRC="${1:?usage: $0 <source-dir> <user@host> <remote-parent-dir> [ssh-key]}"
TARGET="${2:?missing target user@host}"
REMOTE_PARENT="${3:?missing remote parent dir}"
KEY="${4:-$HOME/.ssh/id_ed25519}"

[ -d "$SRC" ] || { echo "$SRC does not exist on $(hostname -s)" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M)"
DEST="$REMOTE_PARENT/$(basename "$SRC")-$STAMP"

# rsync runs under sudo so it can read other users' private directories, which
# means its ssh runs as root. Root has no keys of its own here, so point it at
# the admin key explicitly.
SSH_CMD="ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" \
  "sudo mkdir -p '$DEST' && sudo chmod 700 '$DEST'"

# -aAX --numeric-ids preserves ownership, modes, ACLs and xattrs. Anything less
# and you restore a backup that no longer belongs to the right people.
sudo rsync -aAX --numeric-ids --info=stats2 \
  -e "$SSH_CMD" --rsync-path="sudo rsync" \
  "$SRC/" "$TARGET:$DEST/"

echo
echo "source files:      $(sudo find "$SRC" | wc -l)"
echo "backup files:      $(ssh -i "$KEY" -o BatchMode=yes "$TARGET" "sudo find '$DEST' | wc -l")"
echo "backup location:   $TARGET:$DEST"
