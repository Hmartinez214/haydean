#!/bin/bash
# Format /dev/sdb as XFS and mount it as this node's BeeGFS storage target.
# Refuses to run if sdb carries any filesystem signature.
set -euo pipefail

DEV=/dev/sdb
MNT=/data/beegfs/storage

if sudo blkid "$DEV" >/dev/null 2>&1; then
  echo "$(hostname -s): $DEV already has a signature, refusing to format"
  exit 1
fi

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y xfsprogs >/dev/null 2>&1

sudo mkfs.xfs -q -L beegfs-stor "$DEV"
sudo mkdir -p "$MNT"

UUID=$(sudo blkid -s UUID -o value "$DEV")
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MNT xfs defaults,noatime,nodiratime 0 2" | sudo tee -a /etc/fstab >/dev/null
fi

sudo systemctl daemon-reload
sudo mount "$MNT"

echo "$(hostname -s): $(df -h --output=size,avail,fstype,target "$MNT" | tail -1)"
