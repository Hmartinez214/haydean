#!/bin/bash
#SBATCH --job-name=mdtest
#SBATCH --partition=no_dinos
#SBATCH --output=/home/hpcadmin/storagebenchmarks/logs/mdtest-%j.out
#SBATCH --error=/home/hpcadmin/storagebenchmarks/logs/mdtest-%j.out
#SBATCH --time=02:00:00
#
# Driven by env vars passed with --export:
#   TARGET  - directory to test (must exist, be writable from all nodes)
#   NFILES  - files/dirs per rank
#   ITER    - iterations
#   TAG     - label for the result file
#   EXTRA   - extra mdtest flags (e.g. "-u" for unique dir per rank)

MDTEST=/home/hpcadmin/storagebenchmarks/opt/bin/mdtest
RESULTS=/home/hpcadmin/storagebenchmarks/results

: "${NFILES:=100}"
: "${ITER:=1}"
: "${EXTRA:=}"
: "${TAG:=run}"

# stride the stat phase by tasks-per-node so a rank stats files created on a
# different node -- defeats local client-side metadata caching on NFS.
STRIDE=${SLURM_NTASKS_PER_NODE:-1}

OUT="$RESULTS/${TAG}_n${SLURM_NTASKS}.txt"

{
  echo "### mdtest $TAG"
  echo "date       : $(date -Is)"
  echo "nodelist   : $SLURM_JOB_NODELIST"
  echo "ntasks     : $SLURM_NTASKS  (${SLURM_NNODES} nodes x ${STRIDE} ranks)"
  echo "target     : $TARGET"
  echo "files/rank : $NFILES   iterations: $ITER   extra: '$EXTRA'"
  echo "stride -N  : $STRIDE"
  echo "###"
} | tee "$OUT"

mkdir -p "$TARGET"

# --use-hwthread-cpus: Slurm advertises 12 CPUs/node (6 cores x 2 threads) but
# PRRTE counts only physical cores as slots, so >6 ranks/node aborts with
# "allocation-overload". --bind-to none keeps ranks off fixed hwthreads; this is
# a metadata benchmark, so it is I/O bound rather than CPU bound.
mpirun --use-hwthread-cpus --bind-to none -n "$SLURM_NTASKS" "$MDTEST" \
    -d "$TARGET" \
    -n "$NFILES" \
    -i "$ITER" \
    -N "$STRIDE" \
    $EXTRA 2>&1 | tee -a "$OUT"

echo "--- mdtest exit=${PIPESTATUS[0]} ---" | tee -a "$OUT"

# leave the target clean for the next run
rm -rf "${TARGET:?}"/* 2>/dev/null
