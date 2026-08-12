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
