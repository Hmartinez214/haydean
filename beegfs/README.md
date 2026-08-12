# Migrating a shared directory from NFS to BeeGFS

What was done to this cluster, why, and how to do it again from scratch.

Addresses and hostnames here are placeholders. Real values live in
`scripts/cluster.env`, which is gitignored and exists only on the admin
machine and the cluster itself.

Operational reference (verification, troubleshooting, rollback) lives in
[RUNBOOK.md](RUNBOOK.md). This document covers what happened and how to
repeat it.

## What changed

A shared directory that was NFS-exported from a single compute node now runs
on BeeGFS, striped across the previously unused second disk in all four
compute nodes. Home directories were deliberately left on NFS.

| Path | Before | After |
|---|---|---|
| `/home` | NFS from the login node | unchanged, still NFS |
| `/shared` | NFS from node1, mounted by node2-4 | BeeGFS, mounted by login and node1-4 |

Result: 447G usable, 30GB of live data migrated across 333,879 files with
ownership and permissions preserved, no downtime for `/home`, and the original
NFS directory retained as a rollback.

## The cluster

Six nodes, Ubuntu 26.04 ("resolute"), kernel 7.0.0, every link 1 GbE.

| Node | Role | Disks |
|---|---|---|
| login | Slurm controller, NFS server for `/home` | 1.8T single disk |
| node1 | compute, was the NFS server for `/shared` | 224G OS + 112G unused |
| node2 | compute | 224G OS + 112G unused |
| node3 | compute | 224G OS + 112G unused |
| node4 | compute | 224G OS + 112G unused |
| gpu | GPU node, different subnet, routed | 466G + 932G |

The four unused 112G disks are the entire reason this was worth doing.

## Service layout

| Node | mgmtd | meta | storage | client |
|---|:--:|:--:|:--:|:--:|
| login | yes | | | yes |
| node1 | | yes | yes | yes |
| node2 | | yes | yes | yes |
| node3 | | | yes | yes |
| node4 | | | yes | yes |
| gpu | | | | no |

Metadata lives on the OS filesystem of node1 and node2 rather than carving up
the second disk, which keeps all four storage targets a uniform 112G.

## Why it was built this way

**Why BeeGFS helps here, and where it does not.** At 1 GbE a single client
tops out near 117 MB/s regardless of the filesystem underneath, which is where
NFS already sat. Single-job throughput does not improve. The gain is
aggregate: four storage servers serve roughly 470 MB/s combined when several
jobs do I/O at once. Worth doing for many-client contention, not for making
one job faster.

**Why `/home` stayed on NFS.** The BeeGFS pool is 447G. The `/home` volume has
1.7T free. Moving home directories onto BeeGFS would have cut available space
roughly fourfold, on a filesystem with no redundancy.

**Why no mirroring, and what that costs.** Buddy mirroring would halve usable
capacity to ~223G, still ample for 27G of data. It was declined in favour of
taking an independent backup instead. The consequence is recorded plainly:
the stripe pattern is `RAID0 (4x512K)`, so any file over 512K has pieces on
all four nodes, and losing one node's disk damages most files rather than a
quarter of them. **This filesystem is not a backup and does not survive a
single disk failure.**

**Why services are pinned to one interface.** Every node runs Tailscale.
BeeGFS advertises all interfaces by default, so without pinning, nodes
discover each other over the VPN and every storage operation gets encrypted
and routed the long way round.

**Why the GPU node was excluded.** It sits on a different subnet, reaching the
cluster through a router rather than the cluster switch. It keeps its NFS home
mount. Adding it as a client is viable (measured 0.31 ms to the login node)
but was left as a follow-up.

## Reproducing this

### Prerequisites

- Passwordless `sudo` on every node for the admin account
- Passwordless SSH from the management node to every other node
- A dedicated, empty block device on each intended storage node
- Outbound HTTPS from the nodes to reach the BeeGFS package repo

### Setup

Copy `scripts/cluster.env.example` to `scripts/cluster.env` and fill it in.
Everything else reads from that file, so it is the only place hostnames and
addresses appear.

```bash
cp scripts/cluster.env.example scripts/cluster.env
$EDITOR scripts/cluster.env
```

Distribute the scripts to every node, for example:

```bash
scp -r scripts admin@login:~/beegfs-deploy
ssh admin@login 'for h in node1 node2 node3 node4; do scp -rq ~/beegfs-deploy $h:~/; done'
```

### Run, in this order

```bash
# 1. Package repository, on every node
bash ~/beegfs-deploy/01-add-repo.sh

# 2. Packages by role, on every node. Each node works out its own role.
bash ~/beegfs-deploy/02-install-packages.sh

# 3. Storage targets, on each storage node. Destroys the target disk.
bash ~/beegfs-deploy/03-prepare-storage.sh

# 4. Shared connection secret, on the management node only.
#    Generates it and copies it to every node.
bash ~/beegfs-deploy/00-conn-auth.sh

# 5. Services, strictly in this order
bash ~/beegfs-deploy/04-configure-service.sh mgmtd     # management node
bash ~/beegfs-deploy/04-configure-service.sh meta      # each metadata node
bash ~/beegfs-deploy/04-configure-service.sh storage   # each storage node
bash ~/beegfs-deploy/04-configure-service.sh client    # each client node
```

At this point the filesystem is mounted at `BEEGFS_MOUNT` and empty. Verify
before putting data on it:

```bash
beegfs --tls-disable health check
df -hT /mnt/beegfs
```

All targets should read `Online`, `Good`, `Healthy`, and the connection check
should report `All connections are using preferred NICs and protocols`.

### Migrating data off NFS

```bash
# 6. First copy. Non-destructive, runs while the cluster is live, repeatable.
#    Run on the node that holds the source directory locally.
bash ~/beegfs-deploy/05-migrate-data.sh /shared

# 7. Independent backup, to a machine that is NOT a storage node.
bash ~/beegfs-deploy/06-backup.sh /shared admin@backup-host /data ~/.ssh/id_ed25519

# 8. Cutover. The only destructive step, and it renames rather than deletes.
#    Refuses to run unless the queue is empty and the backup is complete.
bash ~/beegfs-deploy/07-cutover.sh node1 /shared backup-host /data/shared-TIMESTAMP --confirm
```

`07-cutover.sh` does the final delta sync, verifies file counts, removes the
NFS export, unmounts the old mount everywhere, renames the original to
`/shared.nfs-retired`, then repoints the BeeGFS mount to `/shared` on every
client.

### Verifying the migration

The authoritative check is an rsync dry run between the retired original and
the new filesystem:

```bash
sudo rsync -aAXn --numeric-ids --itemize-changes /shared.nfs-retired/ /shared/
```

Expect output only for symlinks, itemized `.L...p.....`, meaning permission
bits differ. BeeGFS reports symlink modes as 755 where local filesystems
report 777. Linux does not use symlink permission bits for access control, so
this has no effect. Any line for a regular file or directory is a real problem
and should be investigated before you trust the copy.

On this cluster that check returned 6,669 items, exactly the symlink count,
and nothing else.

## Scripts

| Script | Purpose | Reversible |
|---|---|---|
| `01-add-repo.sh` | BeeGFS 8.4 apt repo and keyring | yes, delete two files |
| `02-install-packages.sh` | Packages by role | yes, apt remove |
| `03-prepare-storage.sh` | Format and mount the target disk | no, destroys the disk |
| `00-conn-auth.sh` | Generate and distribute the shared secret | yes |
| `04-configure-service.sh` | Configure and start one service | yes |
| `05-migrate-data.sh` | Copy data onto BeeGFS | yes, source untouched |
| `06-backup.sh` | Independent off-cluster backup | yes |
| `07-cutover.sh` | Switch the mount point over | yes, see RUNBOOK |
| `99-rebuild-fstab.sh` | Reconstruct a lost fstab from blkid | recovery tool |

All are idempotent. `03-prepare-storage.sh` refuses to touch a disk that
already carries a filesystem signature, and `07-cutover.sh` refuses to run
with jobs queued or without a verified backup.

## Things worth knowing before you start

Full detail with exact error messages is in [RUNBOOK.md](RUNBOOK.md). In
short:

- BeeGFS 8 needs its management database created with `--init`, which exits
  non-zero on success and will trip `set -e`
- A shared secret at `/etc/beegfs/conn.auth` is mandatory and must be
  identical on every node
- `beegfs-client-dkms` ships no systemd unit; clients mount via fstab
- Services must be pinned to the cluster interface or they will use the VPN
- BeeGFS 8 requires a license. The community tier is free but must be
  registered, and some configuration (capacity pool thresholds) is gated
  behind it
- The retired NFS fstab entry will hijack the new mount point if you do not
  disable it first
- Never build `/etc/fstab` with a shell redirect; a failed command truncates
  it and the node will not boot

## Follow-ups on this cluster

- Community license not yet installed, which also blocks capacity pool tuning
- The GPU node's second NIC is cabled to the cluster segment and DHCP offers
  an address, but netplan has no `dhcp4` for it
- The GPU node is not a BeeGFS client
- The backup is a one-time snapshot. If this data matters, put `06-backup.sh`
  on a schedule
- The NFS exports predating this work were world-exported with
  `no_root_squash`, which is worth tightening independently
