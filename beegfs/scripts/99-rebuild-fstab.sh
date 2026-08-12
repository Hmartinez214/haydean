#!/bin/bash
# Rebuild /etc/fstab on a compute node from the node's own blkid output.
# Reads UUIDs locally so nothing is hardcoded per host.
# Writes a candidate, validates it, and only then installs it.
set -euo pipefail

SDA1="$(sudo blkid -s UUID -o value /dev/sda1)"
SDA2="$(sudo blkid -s UUID -o value /dev/sda2)"
SDB="$(sudo blkid -s UUID -o value /dev/sdb)"

for v in "$SDA1" "$SDA2" "$SDB"; do
  [ -n "$v" ] || { echo "$(hostname -s): missing a UUID, aborting" >&2; exit 1; }
done

TMP=/tmp/fstab.candidate
cat > "$TMP" <<EOF
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
# / was on /dev/sda2 during curtin installation
/dev/disk/by-uuid/$SDA2 / ext4 defaults 0 1
# /boot/efi was on /dev/sda1 during curtin installation
/dev/disk/by-uuid/$SDA1 /boot/efi vfat defaults 0 1
/swap.img	none	swap	sw	0	0

haydeanlogin.local:/home /home nfs defaults,_netdev 0 0
# Retired at BeeGFS cutover. Re-enable this and comment the beegfs line below
# to roll back to NFS.
# haydean1.local:/haydean /haydean nfs defaults,_netdev 0 0
UUID=$SDB /data/beegfs/storage xfs defaults,noatime,nodiratime 0 2
beegfs_nodev /haydean beegfs defaults,cfgFile=/etc/beegfs/beegfs-client.conf,_netdev 0 0
EOF

# Sanity gates before this replaces a file the machine needs to boot.
grep -q " / ext4 " "$TMP"      || { echo "$(hostname -s): no root entry, aborting" >&2; exit 1; }
grep -q " /boot/efi vfat " "$TMP" || { echo "$(hostname -s): no efi entry, aborting" >&2; exit 1; }
[ "$(wc -l < "$TMP")" -ge 15 ] || { echo "$(hostname -s): candidate too short, aborting" >&2; exit 1; }

if command -v findmnt >/dev/null; then
  sudo findmnt --verify --fstab "$TMP" >/dev/null 2>&1 \
    || echo "$(hostname -s): findmnt reported warnings, review below"
fi

sudo install -o root -g root -m 644 "$TMP" /etc/fstab
rm -f "$TMP"
sudo systemctl daemon-reload

mountpoint -q /haydean || sudo mount /haydean || true

echo "$(hostname -s): fstab rebuilt ($(wc -l < /etc/fstab) lines), /haydean mounted: $(mountpoint -q /haydean && echo yes || echo NO)"
