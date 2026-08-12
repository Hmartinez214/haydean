#!/bin/bash
# add_user.sh — Rocky port
# Usage: sudo ./add_user.sh <username> [--admin]
# Adds a user across all cluster nodes with limited permissions and Slurm access.
#
# Changes from the Ubuntu original:
#   usermod -aG sudo  →  usermod -aG wheel      *** THE IMPORTANT ONE ***
#     Rocky's admin group is `wheel`; there is no `sudo` group. On Ubuntu the
#     --admin flag worked; ported verbatim it would silently fail (usermod
#     errors on a missing group) and the user would get no admin rights.
#   sshpass install hint: apt → dnf
#   Added `nano` to the install check — the .bashrc sets EDITOR=nano but Rocky
#     minimal does not ship it.
#   Added SELinux note/handling for NFS homes (see nfs.sh: use_nfs_home_dirs).
#   /etc/bashrc sourcing in the generated .bashrc was already RHEL-style and
#     needed no change (on Ubuntu that path did not exist, so this actually
#     works better here).

set -euo pipefail
# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <username> [--admin]"
  exit 1
fi

NEW_USER="$1"
IS_ADMIN=false
[[ "${2:-}" == "--admin" ]] && IS_ADMIN=true

CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"
SSH_USER="hpcadmin"

# Rocky's administrative group. Ubuntu used `sudo`.
ADMIN_GROUP="wheel"

# ── Preflight checks ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)"
  exit 1
fi

if ! command -v sshpass &>/dev/null; then
  echo "ERROR: sshpass not installed (sudo dnf install sshpass — needs EPEL)"
  exit 1
fi

if [[ ! -f "$PASS_FILE" ]]; then
  echo "ERROR: $PASS_FILE not found"
  exit 1
fi

if [[ ! -f "$CLUSTER_FILE" ]]; then
  echo "ERROR: $CLUSTER_FILE not found"
  exit 1
fi

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

mapfile -t nodes < <(tr -d '\r' < "$CLUSTER_FILE")
LOGIN="$(hostname)"

# Pick a consistent UID across all nodes (critical for NFS, and for BeeGFS later)
if id "$NEW_USER" >/dev/null 2>&1; then
    NEW_UID=$(id -u "$NEW_USER")
    NEW_GID=$(id -g "$NEW_USER")

    echo "Existing user detected:"
    echo " UID=$NEW_UID"
    echo " GID=$NEW_GID"
else
    NEW_UID=$(awk -F: '$3 >= 2000 && $3 < 60000 {print $3}' /etc/passwd /etc/group | sort -n | tail -1)
    NEW_UID=$(( ${NEW_UID:-1999} + 1 ))
    NEW_GID=$NEW_UID
fi

echo "== Adding user: $NEW_USER (UID=$NEW_UID, GID=$NEW_GID) =="
echo "   Admin: $IS_ADMIN (group: $ADMIN_GROUP)"
echo "   Nodes: ${nodes[*]} + $LOGIN"

# ── Generate .bashrc content ──────────────────────────────────────────────────
BASHRC_CONTENT=$(cat << 'BASHRC'
# ~/.bashrc for cluster user

# Source global definitions
[ -f /etc/bashrc ] && . /etc/bashrc

# ── Prompt ────────────────────────────────────────────────────────────────────
PS1='\[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '

# ── Environment ───────────────────────────────────────────────────────────────
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
export EDITOR=nano

# ── Slurm helpers ─────────────────────────────────────────────────────────────
alias sq='squeue --me'
alias si='sinfo -o "%P %a %D %C %l"'
alias slog='tail -f /var/log/slurm/slurmd.log'

# ── Job submission helpers ─────────────────────────────────────────────────────
# Usage: srun_interactive [nodes] [cpus]
srun_interactive() {
  local nodes="${1:-1}"
  local cpus="${2:-1}"
  srun --nodes="$nodes" --ntasks-per-node="$cpus" --pty bash
}

[[ $- != *i* ]] && return

BASHRC
)

# ── Step 1: Create user on all nodes ─────────────────────────────────────────
echo ""
echo "== Step 1: Creating user on all nodes =="

ALL_HOSTS=("$LOGIN" "${nodes[@]}")

for host in "${ALL_HOSTS[@]}"; do
  [ -z "$host" ] && continue
  echo "[$host] creating user $NEW_USER"

  if [[ "$host" == "$LOGIN" ]]; then
    # Run locally — no SSH needed, avoids TTY issue
    sudo bash << LOCALSH
      if ! getent group $NEW_USER > /dev/null 2>&1; then
        groupadd -g $NEW_GID $NEW_USER
      fi
      if ! id $NEW_USER > /dev/null 2>&1; then
        useradd -u $NEW_UID -g $NEW_GID -m -s /bin/bash -c "Cluster User" $NEW_USER
        echo "  Created user $NEW_USER"
      else
        echo "Existing user: $NEW_USER"
      fi
      # Rocky: admin group is wheel, not sudo
      [ "$IS_ADMIN" = "true" ] && usermod -aG $ADMIN_GROUP $NEW_USER && echo "  Added to $ADMIN_GROUP"
      echo "$NEW_USER:changeme123" | chpasswd
      chage -M 365 $NEW_USER
      # Add to hpcusers for password-change sudo access
      if ! getent group hpcusers > /dev/null 2>&1; then
        groupadd hpcusers
      fi
      usermod -aG hpcusers $NEW_USER
      echo "  Added $NEW_USER to hpcusers"
LOCALSH
  else
    sshpass -e ssh $SSH_OPTS "$SSH_USER@$host" \
"NEW_USER='$NEW_USER' NEW_UID='$NEW_UID' NEW_GID='$NEW_GID' IS_ADMIN='$IS_ADMIN' ADMIN_GROUP='$ADMIN_GROUP' bash -s" << 'ENDSSH'

if ! getent group "$NEW_USER" > /dev/null 2>&1; then
    sudo groupadd -g "$NEW_GID" "$NEW_USER"
fi

if ! id "$NEW_USER" > /dev/null 2>&1; then
    sudo useradd -u "$NEW_UID" -g "$NEW_GID" -m -s /bin/bash \
        -c "Cluster User" "$NEW_USER"
    echo "  Created user $NEW_USER"
else
    EXISTING_UID=$(id -u "$NEW_USER")
    EXISTING_GID=$(id -g "$NEW_USER")

    if [ "$EXISTING_UID" != "$NEW_UID" ] || [ "$EXISTING_GID" != "$NEW_GID" ]; then
        echo "  Fixing UID/GID mismatch:"
        echo "    Existing: $EXISTING_UID:$EXISTING_GID"
        echo "    Expected: $NEW_UID:$NEW_GID"

        sudo usermod -u "$NEW_UID" "$NEW_USER"
        sudo groupmod -g "$NEW_GID" "$NEW_USER"
    fi

    echo "  User exists"
fi

# Rocky: admin group is wheel, not sudo
if [ "$IS_ADMIN" = "true" ]; then
    sudo usermod -aG "$ADMIN_GROUP" "$NEW_USER"
fi

echo "$NEW_USER:changeme123" | sudo chpasswd
sudo chage -M 365 "$NEW_USER"

if ! getent group hpcusers > /dev/null 2>&1; then
    sudo groupadd hpcusers
fi

sudo usermod -aG hpcusers "$NEW_USER"

echo "  Added $NEW_USER to hpcusers"

ENDSSH
  fi
  [[ $? -ne 0 ]] && echo "FAILED: $host"
done

# Fix ownership now that user exists on all nodes
echo "  Fixing ownership of /home/$NEW_USER"
sudo chown -R "$NEW_UID:$NEW_GID" "/home/$NEW_USER"

# ── Step 2: Set up SSH keys (home is shared so only needs to happen once) ─────
echo ""
echo "== Step 2: Setting up SSH keys for $NEW_USER (shared home, runs once) =="
NEW_HOME="/home/$NEW_USER"
sudo mkdir -p "$NEW_HOME/.ssh"
sudo ssh-keygen -t ed25519 -N '' -f "$NEW_HOME/.ssh/id_ed25519" -C "$NEW_USER@haydean" <<< n 2>/dev/null \
  || echo "  Key already exists, skipping"
sudo cp "$NEW_HOME/.ssh/id_ed25519.pub" "$NEW_HOME/.ssh/authorized_keys"
sudo chmod 700 "$NEW_HOME/.ssh"
sudo chmod 600 "$NEW_HOME/.ssh/authorized_keys" "$NEW_HOME/.ssh/id_ed25519"
sudo chown -R "$NEW_UID:$NEW_GID" "$NEW_HOME/.ssh"
sudo chown "$NEW_UID:$NEW_GID" "/home/$NEW_USER"

# SELinux: the login node serves /home locally, so contexts apply here.
# On the compute nodes /home arrives over NFS and SELinux uses the
# use_nfs_home_dirs boolean instead — set by nfs.sh.
if command -v restorecon &>/dev/null && [[ "$(stat -f -c %T /home)" != "nfs" ]]; then
  sudo restorecon -R "$NEW_HOME" 2>/dev/null || true
  echo "  restored SELinux contexts on $NEW_HOME"
fi

# ── Step 2b: Distribute authorized_keys to all nodes ─────────────────────────
echo ""
echo "== Step 2b: Distributing SSH authorized_keys to all nodes =="

AUTH_KEYS_FILE="$NEW_HOME/.ssh/authorized_keys"

# Start fresh from the user's own public key
sudo cp "$NEW_HOME/.ssh/id_ed25519.pub" "$AUTH_KEYS_FILE"

# Also pull hpcadmin's keys from each node so the user can ssh node-to-node
for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  echo "[$host] checking for node-local keys"
  sshpass -e ssh $SSH_OPTS "$SSH_USER@$host" \
    "cat /local/hpcadmin_ssh/id_ed25519.pub 2>/dev/null || true" \
    >> "$AUTH_KEYS_FILE" 2>/dev/null || true
done

# Deduplicate
sudo sort -u "$AUTH_KEYS_FILE" -o "$AUTH_KEYS_FILE"
sudo chown "$NEW_UID:$NEW_GID" "$AUTH_KEYS_FILE"
sudo chmod 600 "$AUTH_KEYS_FILE"

echo "  authorized_keys contains $(wc -l < "$AUTH_KEYS_FILE") key(s)"
echo "  Keys:"
sudo cat "$AUTH_KEYS_FILE" | awk '{print "    " $3}'

echo ""

# ── Step 3: Write .bashrc (shared home, runs once) ────────────────────────────
echo ""
echo "== Step 3: Writing .bashrc =="
echo "$BASHRC_CONTENT" | sudo tee "$NEW_HOME/.bashrc" > /dev/null
sudo chown "$NEW_UID:$NEW_GID" "$NEW_HOME/.bashrc"
echo "  Written to $NEW_HOME/.bashrc"

# ── Step 4: PAM limits ────────────────────────────────────────────────────────
echo ""
echo "== Step 4: Setting PAM resource limits on all nodes =="
LIMITS_CONF="/etc/security/limits.d/cluster-users.conf"
LIMITS_LINE="$NEW_USER  hard  nproc 256
$NEW_USER  hard  nofile 4096"

for host in "${ALL_HOSTS[@]}"; do
  [ -z "$host" ] && continue
  if [[ "$host" == "$LOGIN" ]]; then
    if [ ! -f $LIMITS_CONF ]; then
      echo '# Cluster user limits' | sudo tee $LIMITS_CONF > /dev/null
    fi
    sudo sed -i "/^${NEW_USER}[[:space:]]/d" $LIMITS_CONF
    echo "${LIMITS_LINE}" | sudo tee -a $LIMITS_CONF > /dev/null
    echo "  [${host}] limits written"
  else
    sshpass -e ssh $SSH_OPTS "$SSH_USER@${host}" "
      if [ ! -f $LIMITS_CONF ]; then
        echo '# Cluster user limits' | sudo tee $LIMITS_CONF > /dev/null
      fi
      sudo sed -i '/^${NEW_USER}[[:space:]]/d' $LIMITS_CONF
      echo '${LIMITS_LINE}' | sudo tee -a $LIMITS_CONF > /dev/null
      echo '  [${host}] limits written'
    " || echo "FAILED limits: $host"
  fi
done

# ── Step 5: Slurm account ─────────────────────────────────────────────────────
echo ""
echo "== Step 5: Adding $NEW_USER to Slurm =="
if command -v sacctmgr &>/dev/null; then
  sudo sacctmgr -i add account "$NEW_USER" Description="User account for $NEW_USER" \
    || echo "  Account may already exist"
  sudo sacctmgr -i add user "$NEW_USER" DefaultAccount="$NEW_USER" \
    || echo "  User may already exist in Slurm"
  echo "  Slurm account created"
else
  echo "  sacctmgr not found — skipping"
fi

# ── Step 6: Create user folder in /haydean (hosted on haydean1) ──────────────
echo ""
echo "== Step 6: Creating /haydean/$NEW_USER on all nodes =="

HAYDEAN_DIR="/haydean/$NEW_USER"

sshpass -e ssh $SSH_OPTS "$SSH_USER@${nodes[0]}" "
  sudo -n mkdir -p $HAYDEAN_DIR
  sudo -n chown $NEW_UID:$NEW_GID $HAYDEAN_DIR
  sudo -n chmod 700 $HAYDEAN_DIR
  echo '  Created $HAYDEAN_DIR on ${nodes[0]}'
" || echo "FAILED: could not create $HAYDEAN_DIR on ${nodes[0]}"

echo "  Verifying /haydean visibility on all nodes:"
for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  result=$(sshpass -e ssh $SSH_OPTS "$SSH_USER@$host" "
    if [ -d $HAYDEAN_DIR ]; then
      mount_info=\$(df $HAYDEAN_DIR 2>/dev/null | tail -1)
      if echo \"\$mount_info\" | grep -q ':'; then
        echo 'OK (NFS)'
      else
        echo 'OK (local/server)'
      fi
    else
      echo 'MISSING'
    fi
  " 2>/dev/null || echo "UNREACHABLE")
  echo "  [$host] $result"
done

# Add HAYDEAN env var to the user's .bashrc
sudo tee -a "/home/$NEW_USER/.bashrc" > /dev/null << EOF

# Shared scratch space on /haydean
export HAYDEAN="/haydean/$NEW_USER"
alias cdh='cd \$HAYDEAN'
EOF
sudo chown "$NEW_UID:$NEW_GID" "/home/$NEW_USER/.bashrc"
echo "  Added \$HAYDEAN env var to .bashrc"

echo ""
echo "== DONE =="
echo "   User:     $NEW_USER"
echo "   UID/GID:  $NEW_UID/$NEW_GID"
echo "   Password: changeme123 (must change on first login)"
echo "   Home:     $NEW_HOME (on shared storage)"
echo "   SSH key:  $NEW_HOME/.ssh/id_ed25519"
echo ""
echo "User can submit jobs with:"
echo "  sbatch --partition=no_dinos job.sh"
echo "  srun --nodes=1 --ntasks=4 ./program"
