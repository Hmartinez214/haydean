#!/bin/bash
# sync_password.sh — Rocky port
# Usage: sudo ./sync_password.sh <username>
# Copies the password hash from the login node's /etc/shadow to all compute nodes.
#
# Changes from the Ubuntu original: none functionally — /etc/shadow handling is
# identical on Rocky.
#
# WORTH KNOWING for the rebuild: the hash format must match across nodes. Ubuntu
# 26.04 defaults to yescrypt ($y$), Rocky defaults to SHA-512 ($6$). Copying a
# hash between the two distros produces an account nobody can log into. Since
# every node will be Rocky after the rebuild this is consistent again — but do
# NOT carry hashes over from the old Ubuntu install.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "ERROR: run as root"; exit 1; fi
if [[ $# -lt 1 ]]; then echo "Usage: $0 <username>"; exit 1; fi

TARGET_USER="$1"
SSH_USER="hpcadmin"
CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

mapfile -t nodes < <(tr -d '\r' < "$CLUSTER_FILE")

# Extract the shadow line for this user from the login node
SHADOW_LINE=$(grep "^${TARGET_USER}:" /etc/shadow)
if [[ -z "$SHADOW_LINE" ]]; then
  echo "ERROR: $TARGET_USER not found in /etc/shadow"; exit 1
fi
HASH=$(echo "$SHADOW_LINE" | cut -d: -f2)
echo "Syncing password hash for $TARGET_USER to all nodes..."

for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  echo -n "[$host] "
  sshpass -e ssh $SSH_OPTS "$SSH_USER@$host" "
    if ! id $TARGET_USER &>/dev/null; then
      echo 'SKIP: user does not exist'
      exit 0
    fi
    # Replace only the hash field (field 2) in /etc/shadow
    sudo -n sed -i 's|^${TARGET_USER}:[^:]*:|${TARGET_USER}:${HASH}:|' /etc/shadow
    echo 'OK'
  " || echo "FAILED"
done

echo "Done. Password hash synced to all nodes."
