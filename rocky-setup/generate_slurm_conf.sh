#!/bin/bash
# Rocky port of generate_slurm_conf.sh
#
# Changes from the Ubuntu original:
#   /var/run/*.pid → /run/slurm/*.pid  — Rocky clears /var/run on boot; the
#     matching tmpfiles.d rule is installed by setup_slurm.sh.
#   Everything else is OS-independent (this only writes a text file).
#
# NOTE carried over from the original, unchanged but worth knowing:
#   RealMemory is not set, so Slurm reports RealMemory=1 for every node. That is
#   harmless with SelectTypeParameters=CR_Core (memory is not a consumable
#   resource) but means --mem requests cannot be honoured. Set RealMemory per
#   node if you ever switch to CR_Core_Memory.

CLUSTER_FILE="cluster.txt"
OUTPUT="slurm.conf"

CLUSTER_NAME="haydean"

# FIX: avoid double .local
CONTROLLER=$(hostname)
CONTROLLER="${CONTROLLER%.local}"

DEFAULT_CPUS=12
DEFAULT_SOCKETS=1
DEFAULT_CPS=6
DEFAULT_THREADS=2

echo "Generating Slurm config..."

# Clean input
mapfile -t nodes < <(sed 's/\r//g' "$CLUSTER_FILE" | grep -v '^$')

echo "Nodes found: ${#nodes[@]}"

# Strip .local for consistency in Slurm naming
for i in "${!nodes[@]}"; do
  nodes[$i]="${nodes[$i]%.local}"
done

# Build NodeName using RANGE (correct Slurm style)
NODE_RANGE="${CLUSTER_NAME}[1-${#nodes[@]}]"

NODE_LINE="NodeName=${NODE_RANGE} CPUs=${DEFAULT_CPUS} Sockets=${DEFAULT_SOCKETS} CoresPerSocket=${DEFAULT_CPS} ThreadsPerCore=${DEFAULT_THREADS} State=UNKNOWN"

# Partition uses SAME naming style
PARTITION_LINE="PartitionName=no_dinos Nodes=${NODE_RANGE} Default=YES MaxTime=INFINITE State=UP"

cat > "$OUTPUT" <<EOF
ClusterName=${CLUSTER_NAME}
SlurmctldHost=${CONTROLLER}

MpiDefault=none
ProctrackType=proctrack/linuxproc
ReturnToService=1

SlurmctldPidFile=/run/slurm/slurmctld.pid
SlurmdPidFile=/run/slurm/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd

SlurmUser=slurm
StateSaveLocation=/var/spool/slurmctld

SwitchType=switch/none
TaskPlugin=task/none

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# AccountingStorageType=accounting_storage/none
# JobCompType=jobcomp/none
# JobAcctGatherType=jobacct_gather/none
AccountingStorageType=accounting_storage/slurmdbd
JobAcctGatherType=jobacct_gather/linux
JobCompType=jobcomp/filetxt
JobCompLoc=/var/log/slurm/jobcomp.log
AccountingStorageHost=haydeanlogin
AccountingStoragePort=6819

MailProg=/bin/true

SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# Prevent users from monopolizing the cluster
MaxJobCount=500
MaxArraySize=100
$NODE_LINE

$PARTITION_LINE
EOF

echo "Wrote $OUTPUT"
echo "---- preview ----"
cat "$OUTPUT"
