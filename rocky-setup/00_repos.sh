#!/bin/bash
# 00_repos.sh — Rocky Linux only. No Ubuntu equivalent.
#
# Rocky needs two extra repositories before any of the other scripts will work:
#   EPEL — provides munge, sshpass, and various build deps
#   CRB  — "CodeReady Builder", provides the -devel packages Slurm needs
# It also sets consistent system UIDs for munge/slurm, which matters far more on
# a shared filesystem than it did before: with NFS (and later BeeGFS) a mismatched
# slurm UID between nodes causes permission failures that look like config bugs.
#
# Run on the login node. Distributes to compute nodes over ssh.

set -uo pipefail

USER="hpcadmin"
CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Pin system accounts so UIDs match across every node.
MUNGE_UID=1101
SLURM_UID=1102

mapfile -t nodes < <(tr -d '\r' < "$CLUSTER_FILE")

setup_cmds() {
cat <<'ROCKY'
  set -e
  # EPEL + CRB. CRB is named differently on Rocky 8 vs 9/10.
  sudo -n dnf install -y epel-release
  if sudo -n dnf config-manager --set-enabled crb 2>/dev/null; then
    echo "  enabled crb"
  elif sudo -n dnf config-manager --set-enabled powertools 2>/dev/null; then
    echo "  enabled powertools (Rocky 8)"
  else
    echo "  WARNING: could not enable CRB/PowerTools"
  fi

  sudo -n dnf install -y sshpass rsync tar bzip2 nano

  # Consistent system accounts across the cluster.
  getent group  munge >/dev/null || sudo -n groupadd -g MUNGE_UID_PLACEHOLDER munge
  getent passwd munge >/dev/null || sudo -n useradd -r -u MUNGE_UID_PLACEHOLDER -g munge \
      -d /var/lib/munge -s /sbin/nologin munge
  getent group  slurm >/dev/null || sudo -n groupadd -g SLURM_UID_PLACEHOLDER slurm
  getent passwd slurm >/dev/null || sudo -n useradd -r -u SLURM_UID_PLACEHOLDER -g slurm \
      -d /var/lib/slurm -s /sbin/nologin slurm

  echo "  munge=$(id -u munge) slurm=$(id -u slurm)"
ROCKY
}

CMDS="$(setup_cmds | sed -e "s/MUNGE_UID_PLACEHOLDER/$MUNGE_UID/g" -e "s/SLURM_UID_PLACEHOLDER/$SLURM_UID/g")"

echo "== Login node =="
bash -c "${CMDS//sudo -n /sudo }"

for host in "${nodes[@]}"; do
  host="${host//$'\r'/}"
  [ -z "$host" ] && continue
  echo "== $host =="
  sshpass -e ssh $SSH_OPTS "$USER@$host" "$CMDS" || echo "FAILED: $host"
done

echo "== DONE =="
echo "Verify UIDs match everywhere before continuing:"
echo "  ./run_all.sh 'id -u munge; id -u slurm'"
