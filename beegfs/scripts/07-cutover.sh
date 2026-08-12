#!/bin/bash
# Cut the shared directory over from NFS to BeeGFS.
#
#   usage: 07-cutover.sh <source-node> <source-dir> <backup-host> <backup-dir> --confirm
#
# This is the only destructive step in the deployment, and even it does not
# delete anything: the original directory is renamed, not removed, so rollback
# is a rename and a remount.
#
# Refuses to run unless:
#   - no Slurm jobs are running
#   - the named backup exists and has at least as many files as the source
#   - --confirm is passed
#
# Run from the management node. Requires passwordless ssh to every node.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/cluster.env"

SRC_NODE="${1:?usage: $0 <source-node> <source-dir> <backup-host> <backup-dir> --confirm}"
SRC_DIR="${2:?missing source dir}"
BACKUP_HOST="${3:?missing backup host}"
BACKUP_DIR="${4:?missing backup dir}"
CONFIRM="${5:-}"

RETIRED="${SRC_DIR}.nfs-retired"

say() { echo; echo "== $*"; }

say "gate 1: no running jobs"
JOBS="$(squeue -h 2>/dev/null | wc -l)"
[ "$JOBS" -eq 0 ] || { echo "$JOBS job(s) running, refusing cutover" >&2; exit 1; }
echo "ok, queue empty"

say "gate 2: backup exists and is complete"
SRC_COUNT="$(ssh -o BatchMode=yes "$SRC_NODE" "sudo find '$SRC_DIR' | wc -l")"
BAK_COUNT="$(ssh -o BatchMode=yes "$BACKUP_HOST" "sudo find '$BACKUP_DIR' | wc -l" 2>/dev/null || echo 0)"
echo "source $SRC_COUNT files, backup $BAK_COUNT files"
[ "$BAK_COUNT" -ge "$SRC_COUNT" ] || { echo "backup is incomplete, refusing cutover" >&2; exit 1; }

say "gate 3: confirmation"
[ "$CONFIRM" = "--confirm" ] || { echo "pass --confirm to proceed" >&2; exit 1; }

say "final sync, source to BeeGFS"
ssh -o BatchMode=yes "$SRC_NODE" "bash \$HOME/beegfs-deploy/05-migrate-data.sh '$SRC_DIR' --final"

say "verifying file counts match"
DST_COUNT="$(ssh -o BatchMode=yes "$SRC_NODE" "sudo find '$BEEGFS_MOUNT' | wc -l")"
echo "source $SRC_COUNT, beegfs $DST_COUNT"
[ "$DST_COUNT" -ge "$SRC_COUNT" ] || { echo "copy is short, refusing to continue" >&2; exit 1; }

say "removing the NFS export"
ssh -o BatchMode=yes "$SRC_NODE" \
  "sudo sed -i 's|^\s*$SRC_DIR\s|#&|' /etc/exports 2>/dev/null || true; sudo exportfs -u '*:$SRC_DIR' 2>/dev/null || true; sudo exportfs -ra"

say "unmounting the NFS clients"
for h in $CLIENT_NODES; do
  ssh -o BatchMode=yes "$h" \
    "mountpoint -q '$SRC_DIR' && sudo umount '$SRC_DIR' && echo '$h: unmounted' || echo '$h: nothing mounted'"
done

say "retiring the original directory on $SRC_NODE"
ssh -o BatchMode=yes "$SRC_NODE" \
  "[ -d '$RETIRED' ] || sudo mv '$SRC_DIR' '$RETIRED'; echo kept at $RETIRED"

say "moving the BeeGFS mount to $SRC_DIR on every client"
# Two fstab edits are needed, and the order matters. Nodes that mounted the
# old NFS export still have a line claiming $SRC_DIR; if it is left enabled,
# `mount $SRC_DIR` matches it instead of the BeeGFS line and fails with
# "access denied by server". Comment it out, then repoint the BeeGFS line.
#
# Edits are made with sed -i against a backup copy rather than by redirecting
# into the file: a failed redirect truncates /etc/fstab, which leaves a node
# unable to boot.
for h in $CLIENT_NODES; do
  ssh -o BatchMode=yes "$h" "
    set -e
    sudo mkdir -p '$SRC_DIR'
    mountpoint -q '$BEEGFS_MOUNT' && sudo umount '$BEEGFS_MOUNT' || true

    sudo cp -a /etc/fstab /etc/fstab.pre-beegfs
    # Disable any non-beegfs entry claiming this mount point.
    sudo sed -i -E 's|^([^#][^[:space:]]*[[:space:]]+$SRC_DIR[[:space:]]+(nfs\\|nfs4)[[:space:]].*)|# retired at BeeGFS cutover: \\1|' /etc/fstab
    # Repoint the BeeGFS entry from its staging mount point to the real one.
    sudo sed -i 's|^beegfs_nodev $BEEGFS_MOUNT beegfs|beegfs_nodev $SRC_DIR beegfs|' /etc/fstab

    # Refuse to continue if the edit damaged the file.
    grep -qE '[[:space:]]/[[:space:]]+ext4' /etc/fstab || {
      echo '$h: fstab lost its root entry, restoring backup'; sudo cp -a /etc/fstab.pre-beegfs /etc/fstab; exit 1; }

    sudo systemctl daemon-reload
    sudo mount '$SRC_DIR'
    mountpoint -q '$SRC_DIR' && echo '$h: beegfs at $SRC_DIR' || echo '$h: MOUNT FAILED'
  "
done

say "done"
echo "rollback: umount $SRC_DIR everywhere, mv $RETIRED back to $SRC_DIR,"
echo "          re-enable the export in /etc/exports on $SRC_NODE, exportfs -ra"
