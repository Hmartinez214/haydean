#!/bin/bash
# Submit the full mdtest sweep. All jobs share a job name + --dependency=singleton
# so Slurm runs exactly one at a time -- concurrent jobs would contend for the
# same NFS server and corrupt the numbers.
set -u

cd /home/hpcadmin/storagebenchmarks
SB="sbatch --parsable --exclusive --job-name=mdchain --dependency=singleton"
NFILES=64
ITER=2

HOME_T=/home/hpcadmin/storagebenchmarks/mdtest_home
HAY_T=/haydean/mdtest

submit() { # nodes ranks_per_node target tag extra [nodeopt]
  local nodes=$1 rpn=$2 target=$3 tag=$4 extra=${5:-} nodeopt=${6:-}
  local jid
  jid=$($SB --nodes="$nodes" --ntasks-per-node="$rpn" $nodeopt \
    --export=ALL,TARGET="$target",NFILES=$NFILES,ITER=$ITER,TAG="$tag",EXTRA="$extra" \
    run_mdtest.sbatch)
  echo "$jid  $tag  ${nodes}n x ${rpn} = $((nodes*rpn)) ranks  -> $target"
}

echo "=== Sweep 1: /home (NFS from login node), 4 pure-NFS clients ==="
submit 1 1  "$HOME_T" home4n
for rpn in 1 2 4 8 12; do submit 4 $rpn "$HOME_T" home4n; done

echo "=== Sweep 2: /haydean (NFS from haydean1), 3 pure-NFS clients (server excluded) ==="
for rpn in 1 2 4 8 12; do submit 3 $rpn "$HAY_T" hay3n "" "--exclude=haydean1"; done

echo "=== Sweep 3: /home on the same 3 clients, for apples-to-apples vs sweep 2 ==="
for rpn in 4 12; do submit 3 $rpn "$HOME_T" home3n "" "--exclude=haydean1"; done

echo "=== Sweep 4: shared-dir vs unique-dir-per-rank contention on /home ==="
submit 4 4 "$HOME_T" home4n-uniq "-u"

echo "=== Baseline: node-local ext4 on one node (no NFS) ==="
submit 1 4 /tmp/mdtest_local local1n
