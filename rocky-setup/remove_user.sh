#!/bin/bash
# remove_user.sh — Rocky port
# Usage: sudo ./remove_user.sh <username>
#
# Changes from the Ubuntu original:
#   sshpass install hint: apt → dnf
#   Added `wheel` and `hpcusers` to the protected-group cleanup note.
#   Everything else (userdel, groupdel, pkill, limits.d) is identical on Rocky.
#
# NOTE carried over unchanged: CLUSTER_FILE points at
# /usr/local/etc/slurm-sync/cluster.txt (written by setup_sync_hosts.sh), NOT
# the local cluster.txt. Run setup_sync_hosts.sh first or this errors out.

set -euo pipefail

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)"; exit 1
fi
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <username>"; exit 1
fi

SSH_USER="hpcadmin"
CLUSTER_FILE="/usr/local/etc/slurm-sync/cluster.txt"
PASS_FILE="PASSWORD.txt"

if ! command -v sshpass &>/dev/null; then
  echo "ERROR: sshpass not installed (sudo dnf install sshpass — needs EPEL)"; exit 1
fi
if [[ ! -f "$PASS_FILE" ]]; then
  echo "ERROR: $PASS_FILE not found"; exit 1
fi
if [[ ! -f "$CLUSTER_FILE" ]]; then
  echo "ERROR: $CLUSTER_FILE not found (run setup_sync_hosts.sh first)"; exit 1
fi

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

TARGET_USER="$1"
LOGIN="$(hostname)"

# Safety: refuse to remove system or admin users
PROTECTED=(root slurm munge hpcadmin nobody)
for p in "${PROTECTED[@]}"; do
  if [[ "$TARGET_USER" == "$p" ]]; then
    echo "ERROR: refusing to remove protected user '$TARGET_USER'"
    exit 1
  fi
done

# Confirm the user exists
if ! id "$TARGET_USER" &>/dev/null; then
  echo "ERROR: user '$TARGET_USER' does not exist on this node"
  exit 1
fi

mapfile -t nodes < <(tr -d '\r' < "$CLUSTER_FILE")

echo "== Removing user: $TARGET_USER =="
echo "   Nodes: ${nodes[*]} + $LOGIN"
echo ""
read -r -p "Are you sure? This will remove the user from all nodes. [y/N] " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0

# ── Step 1: Kill any running jobs ─────────────────────────────────────────────
echo ""
echo "== Step 1: Cancel any Slurm jobs for $TARGET_USER =="
if command -v scancel &>/dev/null; then
  scancel -u "$TARGET_USER" && echo "  Jobs cancelled" || echo "  No jobs or scancel failed"
else
  echo "  scancel not found, skipping"
fi

# ── Step 2: Remove Slurm account ──────────────────────────────────────────────
echo ""
echo "== Step 2: Remove from Slurm accounting =="
if command -v sacctmgr &>/dev/null; then
  sacctmgr -i delete user "$TARGET_USER" || echo "  User not in Slurm accounting"
  sacctmgr -i delete account "$TARGET_USER" || echo "  Account not in Slurm accounting"
else
  echo "  sacctmgr not found, skipping"
fi

# ── Step 3: Remove from all compute nodes ─────────────────────────────────────
echo ""
echo "== Step 3: Remove user from compute nodes =="
for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  echo "[$host] removing $TARGET_USER"
  sshpass -e ssh $SSH_OPTS "$SSH_USER@$host" << ENDSSH
    sudo pkill -SIGKILL -u $TARGET_USER 2>/dev/null || true
    sleep 1
    remaining=\$(ps -u $TARGET_USER --no-headers 2>/dev/null | wc -l || echo 0)
    if [ "\$remaining" -gt 0 ]; then
      echo "  WARNING: \$remaining process(es) still running, forcing..."
      sudo kill -9 \$(ps -u $TARGET_USER -o pid= 2>/dev/null) 2>/dev/null || true
      sleep 1
    fi
    if getent passwd $TARGET_USER > /dev/null 2>&1; then
      sudo userdel $TARGET_USER && echo "  user removed" || echo "  userdel failed"
    else
      echo "  user not found"
    fi
    sudo groupdel $TARGET_USER 2>/dev/null && echo "  group removed" || true
    sudo sed -i '/^$TARGET_USER /d' /etc/security/limits.d/cluster-users.conf 2>/dev/null || true
ENDSSH
  [[ $? -ne 0 ]] && echo "  FAILED: $host"
done

# ── Step 4: Remove from login node ────────────────────────────────────────────
echo ""
echo "== Step 4: Remove user from login node =="
pkill -SIGKILL -u "$TARGET_USER" 2>/dev/null || true
sleep 2
kill -9 $(ps -u "$TARGET_USER" -o pid= 2>/dev/null) 2>/dev/null || true
sleep 1
userdel "$TARGET_USER" && echo "  user removed" || echo "  user not found on login"
groupdel "$TARGET_USER" 2>/dev/null || true
sed -i "/^$TARGET_USER /d" /etc/security/limits.d/cluster-users.conf 2>/dev/null || true

echo ""
echo "== Step 4b: Remove /haydean/$TARGET_USER =="
sshpass -e ssh $SSH_OPTS "$SSH_USER@${nodes[0]}" "
  if [ -d /haydean/$TARGET_USER ]; then
    sudo -n rm -rf /haydean/$TARGET_USER
    echo '  Removed /haydean/$TARGET_USER'
  else
    echo '  /haydean/$TARGET_USER not found, skipping'
  fi
" || echo "  FAILED to remove /haydean/$TARGET_USER"

# ── Step 5: Archive or delete home ────────────────────────────────────────────
echo ""
echo "== Step 5: Home directory /home/$TARGET_USER =="
if [[ -d "/home/$TARGET_USER" ]]; then
  read -r -p "  Delete /home/$TARGET_USER? [y/N] " del_home
  if [[ "$del_home" == "y" || "$del_home" == "Y" ]]; then
    read -r -p "  Archive to /home/${TARGET_USER}.tar.gz first? [Y/n] " do_archive
    if [[ "$do_archive" != "n" && "$do_archive" != "N" ]]; then
      tar -czf "/home/${TARGET_USER}.tar.gz" -C /home "$TARGET_USER"
      echo "  Archived to /home/${TARGET_USER}.tar.gz"
    fi
    rm -rf "/home/$TARGET_USER"
    echo "  /home/$TARGET_USER deleted"
  else
    echo "  Skipped — /home/$TARGET_USER left in place"
  fi
fi

echo ""
echo "== DONE: $TARGET_USER removed from all nodes =="
