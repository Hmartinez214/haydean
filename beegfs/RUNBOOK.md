# BeeGFS Runbook

Operational reference for the BeeGFS filesystem on this cluster: how it was
built, how to verify it, how to fix it, and how to undo it.

Addresses here are placeholders. Real values live in `scripts/cluster.env`,
which is gitignored and exists only on the admin machine and the cluster.

## Current state

BeeGFS 8.4.0 on Ubuntu 26.04 ("resolute"), kernel 7.0.0.

| Node | mgmtd | meta | storage | client |
|---|:--:|:--:|:--:|:--:|
| login | yes | | | yes |
| node1 | | yes | yes | yes |
| node2 | | yes | yes | yes |
| node3 | | | yes | yes |
| node4 | | | yes | yes |
| gpu | | | | no |

- Mount point: `/mnt/beegfs`, 447G usable
- Storage targets: one 112G XFS volume per compute node, on a dedicated disk
- Metadata: two targets, on the OS filesystem of node1 and node2
- Stripe pattern: `RAID0 (4x512K)`, unmirrored
- All services pinned to the cluster NIC

## Deployment sequence

Run in this order. Every script is idempotent.

```
01-add-repo.sh            on all nodes    adds the BeeGFS 8.4 apt repo
02-install-packages.sh    on all nodes    installs packages by role
03-prepare-storage.sh     on storage nodes formats and mounts the target disk
00-conn-auth.sh           on mgmt node    generates and distributes the secret
04-configure-service.sh mgmtd    on mgmt node
04-configure-service.sh meta     on meta nodes
04-configure-service.sh storage  on storage nodes
04-configure-service.sh client   on client nodes
05-migrate-data.sh <src>         on the node holding the source data
06-backup.sh <src> <target> <dir> on the node holding the source data
```

`00-conn-auth.sh` is numbered before the service scripts despite its name
because nothing starts without it. Run it after packages are installed, since
it writes into `/etc/beegfs`.

Order matters between roles: mgmtd must be running before meta, meta before
storage, storage before clients mount.

## Things that will bite you

These all cost time during the initial deployment. They are recorded with
their real symptoms so the next person recognises them immediately.

**The management database does not exist until you create it.**

```
No accessible database file found at "/var/lib/beegfs/mgmtd.sqlite"
```

Fix: `beegfs-mgmtd --init`. Note it exits non-zero after succeeding, which
will abort any script running under `set -e`. Guard it with a file test.

**Every node needs an identical shared secret.**

```
Could not open authentication file "/etc/beegfs/conn.auth": No such file or directory
```

BeeGFS 7.2 and later refuse to start without it. Generate once on the
management node and copy to every node with mode 400, owned by root. This is
what `00-conn-auth.sh` does. Losing this file locks the whole filesystem out.

**`beegfs-client-dkms` has no systemd service.**

```
Unit beegfs-client.service could not be found.
```

The DKMS package ships only the kernel module and `/sbin/mount.beegfs`, so
clients mount through `/etc/fstab` like any other filesystem, using
`cfgFile=` and `_netdev`. The separate `beegfs-client` package does provide a
service, but the two conflict, and the DKMS route is preferable because the
module rebuilds automatically on kernel upgrades.

**Pin services to the cluster interface.**

Every node here runs a VPN interface. BeeGFS advertises all interfaces by
default, so without pinning, nodes discover each other over the VPN and every
storage operation gets encrypted and routed the long way. Write the interface
name to `/etc/beegfs/connInterfaces.conf` and point `connInterfacesFile` at
it. For the management service use the `interfaces` key in the TOML.

Confirm it worked with `beegfs health check`, which reports:

```
Fallbacks -> All connections are using preferred NICs and protocols.
```

**BeeGFS 8 requires a license.** Community licenses are free but must be
requested. Without one, tooling warns on every invocation and upstream
warns of "disruptions". Run `beegfs license` to get the registration URL for
this filesystem, place the certificate at `/etc/beegfs/license.pem` on the
management node, then `beegfs license --reload`.

**Capacity pool defaults assume large targets.** The defaults classify
anything under roughly 1TiB as low on space, so 112G targets sit in the "Low"
pool permanently and target selection is skewed. Tune `space-low` and
`space-emergency` in `beegfs-mgmtd.toml`.

**The old NFS fstab entry will hijack the new mount point.** Nodes that
mounted the retired export still have a line claiming that directory. If it is
left enabled, `mount <dir>` matches the NFS line rather than the BeeGFS one:

```
mount.nfs: access denied by server while mounting node1.local:/shared
```

Comment out the stale entry before repointing the BeeGFS line. `07-cutover.sh`
now does both, in that order.

**Never build /etc/fstab with a shell redirect.** If the generating command
fails, the redirect has already truncated the file, and the node is left with
an empty fstab that will not boot. Edit in place with `sed -i` after taking a
backup, and verify the root entry still exists before moving on. If an fstab
is lost, `99-rebuild-fstab.sh` reconstructs one from the node's own `blkid`
output; it validates the candidate and refuses to install anything missing a
root or EFI entry. Check the result with `findmnt --verify`, which should
report `0 parse errors, 0 errors`. Three warnings are normal: the swapfile is
a regular file, and `beegfs_nodev` is a pseudo-device with no detectable
on-disk filesystem type.

**The CLI needs to be told TLS is off.** If the management service runs with
`tls-disable`, every `beegfs` command needs `--tls-disable` too, otherwise:

```
reading certificate file failed: open /etc/beegfs/cert.pem: no such file or directory
```

## Verification

```bash
# Service and target health, run on the management node
beegfs --tls-disable health check
beegfs --tls-disable target list

# Capacity as clients see it
df -hT /mnt/beegfs

# Stripe pattern of a path
beegfs --tls-disable entry info /mnt/beegfs

# Cross-node coherence: write on one node, read on another
echo probe | sudo tee /mnt/beegfs/_probe >/dev/null   # on node1
cat /mnt/beegfs/_probe                                # on node3
```

All targets should report `Online`, `Good`, `Healthy`.

## Operations

**After a kernel upgrade.** DKMS rebuilds the client module automatically.
Confirm with `dkms status | grep beegfs` and check the mount came back after
reboot. The fstab entry uses `_netdev`, so the mount waits for the network.

**Restarting a service.** `systemctl restart beegfs-{mgmtd,meta,storage}`.
Clients are not services; use `umount /mnt/beegfs` and `mount /mnt/beegfs`.
Unmounting requires no processes holding the mount, so check with
`lsof +D /mnt/beegfs` first.

**Adding a storage node.** Run scripts 01, 02, 03, install `conn.auth`, then
`04-configure-service.sh storage`. New targets join the existing pool. Files
already written keep their original stripe pattern and are not rebalanced.

**Checking for filesystem inconsistency.** `beegfs-fsck --checkfs --readOnly`.
Do not run repair modes without understanding what they will change.

## Rollback

The migration is designed so nothing is destroyed until you choose to destroy
it. The original NFS export is unmounted and renamed, never deleted.

To revert to NFS:

1. Unmount BeeGFS on all clients: `umount /mnt/beegfs`
2. Rename the original directory back on the node that served it
3. Re-add its entry to `/etc/exports` and run `exportfs -ra`
4. Remount it on the clients that had it

The BeeGFS services can stay installed and stopped while you decide. To
remove entirely: stop and disable the services, `apt remove` the packages,
and wipe the storage target disks. The metadata directories on the OS
filesystem can be deleted once nothing references them.

## Known limitations

**No redundancy.** The stripe pattern is RAID0 across four targets with 512K
chunks and no mirroring. Any file larger than 512K has pieces on multiple
nodes, so losing one node's storage disk damages most files rather than a
quarter of them. This filesystem is not a backup and does not tolerate a
single disk failure. Keep an independent copy on a machine that is not one of
the storage nodes.

**1 GbE throughput ceiling.** A single client cannot exceed roughly 117 MB/s
regardless of how many storage servers exist. The benefit of this deployment
is aggregate bandwidth when several jobs do I/O at once, not single-job speed.

**Storage servers are compute nodes.** BeeGFS traffic shares the NIC with job
traffic. If job performance regresses after deployment, this is the first
thing to investigate.

## Open items

- Community license not yet installed
- Second NIC on the GPU node is cabled to the cluster segment and gets DHCP
  offers, but netplan has no `dhcp4` for it, so it holds no address
- The GPU node is not a BeeGFS client; it reaches the cluster over a routed
  path and still mounts the NFS home directory
