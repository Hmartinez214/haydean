#!/bin/bash
# BeeGFS vs NFS comparison sweep.
#
# Filesystems as they exist AFTER the BeeGFS cutover:
#   /home     NFS from haydeanlogin, backed by a 7200rpm HDD
#   /haydean  BeeGFS, 4 SSD storage targets + 2 SSD metadata targets
#
# The third data series, NFS-on-SSD, was measured earlier in this session at
# /haydean while it was still NFS from haydean1 (results/hay3n_n{3,6,12}.txt),
# using identical parameters and the same 3-client set. That series is what lets
# us separate "BeeGFS vs NFS" (protocol) from "SSD vs HDD" (media).
#
# All jobs share a name + --dependency=singleton so exactly one runs at a time;
# concurrent jobs would contend for the same servers and corrupt the numbers.

set -u

cd /home/hpcadmin/storagebenchmarks
SB="sbatch --parsable --exclusive --job-name=mdchain --dependency=singleton"
NFILES=64
ITER=2

HOME_T=/home/hpcadmin/storagebenchmarks/mdtest_home   # NFS on HDD
BEE_T=/haydean/mdtest                                 # BeeGFS on SSD

submit() { # nodes ranks_per_node target tag [nodeopt]
  local nodes=$1 rpn=$2 target=$3 tag=$4 nodeopt=${5:-}
  local jid
  jid=$($SB --nodes="$nodes" --ntasks-per-node="$rpn" $nodeopt \
    --export=ALL,TARGET="$target",NFILES=$NFILES,ITER=$ITER,TAG="$tag",EXTRA="" \
    run_mdtest.sbatch)
  echo "  $jid  $tag  ${nodes}n x ${rpn} = $((nodes*rpn)) ranks"
}

# ── Series 1: BeeGFS on 3 clients ────────────────────────────────────────────
# haydean1 excluded so the client set exactly matches the earlier NFS-on-SSD
# baseline (hay3n). This is the apples-to-apples protocol comparison.
echo "== BeeGFS /haydean, 3 clients (matches NFS-on-SSD baseline) =="
for rpn in 1 2 4 8 12; do submit 3 $rpn "$BEE_T" beegfs3n "--exclude=haydean1"; done

# ── Series 2: BeeGFS on all 4 clients ────────────────────────────────────────
echo "== BeeGFS /haydean, 4 clients =="
for rpn in 1 2 4 8 12; do submit 4 $rpn "$BEE_T" beegfs4n; done

# ── Series 3: NFS-on-HDD, 4 clients ──────────────────────────────────────────
# Re-measured on a quiet cluster; the earlier run was contaminated.
echo "== NFS /home (HDD), 4 clients =="
for rpn in 1 2 4 8 12; do submit 4 $rpn "$HOME_T" nfshdd4n; done

echo
echo "Queued: $(squeue -u hpcadmin -h -n mdchain | wc -l) jobs, running one at a time."
