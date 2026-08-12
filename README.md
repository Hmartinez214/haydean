# haydean
## BeeGFS

The shared scratch filesystem now runs on BeeGFS instead of NFS.
See [`beegfs/`](beegfs/) for the deployment scripts, the pre-deployment
survey, and [`beegfs/RUNBOOK.md`](beegfs/RUNBOOK.md) for verification,
troubleshooting and rollback.

## Rocky Linux

The cluster is being rebuilt on Rocky Linux. See [`rocky-setup/`](rocky-setup/)
for the Rocky port of the cluster setup scripts — repos, mDNS, munge, Slurm,
users and NFS — and [`rocky-setup/README.md`](rocky-setup/README.md) for the run
order and the full list of changes from the Ubuntu originals.

Storage in `rocky-setup/` is still NFS: it is a like-for-like OS port, so the
cluster can be brought up first and cut over to BeeGFS separately.

## Storage benchmarks

See [`storagebenchmarks/`](storagebenchmarks/) for the `mdtest` harness used to
compare BeeGFS against NFS, the raw results, and the write-up in
[`storagebenchmarks/RESULTS.md`](storagebenchmarks/RESULTS.md).

Headline: on the **same SSDs**, BeeGFS creates files **1.8×** faster than NFS.
The ~156× figure against `/home` is mostly SSD versus spinning disk, not the
protocol. `/home` is still NFS on one 7200rpm HDD and caps at **58 file
creates/sec**, flat from 4 to 48 ranks — it is now the cluster's bottleneck.

[`storagebenchmarks/RUNBOOK.md`](storagebenchmarks/RUNBOOK.md) covers rebuilding
the harness from scratch. Build artifacts (`opt/`, `src/`, `logs/`) are not
tracked — see that runbook to regenerate them.
