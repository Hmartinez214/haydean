# Haydean BeeGFS Deployment

Scripts and notes for replacing an NFS-exported shared directory with a BeeGFS
parallel filesystem on a small Slurm cluster.

Addresses in this repository are placeholders. The real values are kept in
`docs/survey-raw.txt`, which is gitignored.

## Cluster

Six nodes, all Ubuntu 26.04 ("resolute"), kernel 7.0.0, all links 1 GbE.

| Node | Role | Disks |
|---|---|---|
| login | Slurm controller, NFS server for `/home` | 1.8T single disk |
| node1 | compute, previously NFS server for the shared dir | 224G OS + 112G unused |
| node2 | compute | 224G OS + 112G unused |
| node3 | compute | 224G OS + 112G unused |
| node4 | compute | 224G OS + 112G unused |
| gpu | GPU node, different subnet, routed | 466G + 932G |

### Before

Two independent NFS exports:

- `login:/home` mounted by all nodes
- `node1:/shared` mounted by node2, node3, node4 only

### After

`/home` stays on NFS. The shared directory moves to BeeGFS, built on the
previously unused 112G second disk in each compute node.

| Node | mgmtd | meta | storage | client |
|---|:--:|:--:|:--:|:--:|
| login | yes | | | yes |
| node1 | | yes | yes | yes |
| node2 | | yes | yes | yes |
| node3 | | | yes | yes |
| node4 | | | yes | yes |

Metadata lives on the OS filesystem rather than carving up the second disk,
which keeps all four storage targets a uniform 112G.

## Design notes

**Why BeeGFS helps here, and where it does not.** At 1 GbE a single client
tops out around 117 MB/s regardless of the filesystem underneath, which is
where the previous NFS setup already sat. Single-job throughput does not
improve. The gain is aggregate: four storage servers can serve roughly
470 MB/s combined when several jobs hit the filesystem at once. This
deployment is worthwhile for many-client contention, not for making one job
faster.

**Capacity is smaller than the NFS volume it replaces.** Four 112G targets
give about 447G raw. That comfortably fits the shared directory being
migrated, but it is far less than the free space on the `/home` volume, which
is why `/home` was deliberately left on NFS.

**No mirroring.** Targets are striped with no buddy groups, so all ~447G is
usable and the loss of one node's target loses data on that target. This is
the right tradeoff for scratch that can be regenerated, and it avoids doubling
write traffic on an already saturated 1 GbE link.

**Interface pinning matters.** Every node runs Tailscale, and BeeGFS
advertises all interfaces by default. Without pinning services to the cluster
NIC, nodes will discover and contact each other over WireGuard, which adds
encryption overhead to every storage operation. Each service is restricted to
the cluster interface.

**Storage servers are also compute nodes.** BeeGFS traffic shares the same
1 GbE NIC as job traffic. On a cluster this size that interference is
accepted, but it is the first thing to look at if job performance regresses.

## Scripts

Run in order. Each is idempotent and safe to re-run.

| Script | What it does | Reversible |
|---|---|---|
| `01-add-repo.sh` | Adds the BeeGFS 8.4 apt repo and keyring | yes, delete two files |
| `02-install-packages.sh` | Installs packages by role, keyed off hostname | yes, apt remove |
| `03-prepare-storage.sh` | Formats the second disk XFS, mounts it, adds fstab entry | no, destroys the disk |

`03-prepare-storage.sh` refuses to run if the target disk already carries a
filesystem signature.

## Rollback

The original NFS export is left in place and unmounted rather than deleted
during migration, so reverting means remounting it and stopping the BeeGFS
client. The pre-deployment state is recorded in `docs/pre-deployment-survey.md`.

## Notes for anyone reusing this

The client is a DKMS kernel module. Verify it builds on your kernel before
planning anything else, since that is the step most likely to block the whole
deployment. On kernel 7.0.0 the BeeGFS 8.4 module built without patches.

BeeGFS 8.4 changed the management service configuration to TOML and dropped
the older `beegfs-setup-*` helper tools. Services self-initialize their store
directories on first start via `storeAllowFirstRunInit`.
