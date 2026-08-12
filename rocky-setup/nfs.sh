#!/bin/bash
# Rocky port of nfs.sh
#
# NOTE: the Ubuntu original is TRUNCATED — it ends mid-statement on a bare `if`
# at line 78, so Step 3 (mounting on compute nodes) never actually ran. That
# missing block is completed here; compare against the original before assuming
# behaviour matches.
#
# NOTE: this file is the one slated for replacement by BeeGFS. It is ported
# as-is so the cluster can be brought up on NFS first and cut over separately.
#
# Changes from the Ubuntu original:
#   apt-get                     → dnf
#   nfs-kernel-server           → nfs-utils
#   nfs-common                  → nfs-utils   (one package serves both roles)
#   firewalld rules added       — Rocky enables firewalld by default; NFS needs
#                                 nfs + rpc-bind + mountd opened or mounts hang
#   SELinux boolean added       — use_nfs_home_dirs must be on or ssh key auth
#                                 from an NFS home silently fails (SELinux
#                                 denies sshd reading ~/.ssh over NFS)
#   fstab option `soft`         → `hard` for /home. `soft` risks silent data
#                                 corruption on I/O timeout; it is the wrong
#                                 default for home directories. Kept `_netdev`.

set -uo pipefail

USER="hpcadmin"
CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

mapfile -t nodes < <(tr -d '\r' < "$CLUSTER_FILE")
mainhost="${nodes[0]}"
LOGIN="$(hostname).local"

# Detect subnet from the login node's primary interface for restricted exports
SUBNET=$(ip route | awk '/proto kernel/ && !/^169/ {print $1}' | head -1)
echo "Detected subnet: $SUBNET"
if [[ -z "$SUBNET" ]]; then
  echo "ERROR: could not detect subnet"; exit 1
fi

# ── Step 1: Export /home from login node ─────────────────────────────────────
echo "== Step 1: Setting up /home NFS export on login node =="
sudo dnf install -y nfs-utils

sudo mkdir -p /etc/exports.d

# Idempotent: only add if not already present
EXPORT_LINE="/home $SUBNET(rw,sync,no_subtree_check,root_squash)"
if ! grep -qF "$EXPORT_LINE" /etc/exports.d/home.exports 2>/dev/null; then
  echo "$EXPORT_LINE" | sudo tee /etc/exports.d/home.exports
else
  echo "  /home export already configured, skipping"
fi

sudo exportfs -ra
sudo systemctl enable --now nfs-server

if systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --permanent --add-service=nfs
  sudo firewall-cmd --permanent --add-service=rpc-bind
  sudo firewall-cmd --permanent --add-service=mountd
  sudo firewall-cmd --reload
  echo "  opened NFS in firewalld"
fi

# ── Step 2: Export /haydean from first compute node ──────────────────────────
echo "== Step 2: Setting up /haydean NFS export on $mainhost =="
sshpass -e ssh $SSH_OPTS "$USER@$mainhost" "
  sudo -n dnf install -y nfs-utils

  sudo -n mkdir -p /haydean
  sudo -n mkdir -p /etc/exports.d

  EXPORT_LINE='/haydean $SUBNET(rw,sync,no_subtree_check,root_squash)'
  if ! grep -qF \"\$EXPORT_LINE\" /etc/exports.d/haydean.exports 2>/dev/null; then
    echo \"\$EXPORT_LINE\" | sudo -n tee /etc/exports.d/haydean.exports
  else
    echo '  /haydean export already configured, skipping'
  fi

  sudo -n exportfs -ra
  sudo -n systemctl enable --now nfs-server

  if systemctl is-active --quiet firewalld; then
    sudo -n firewall-cmd --permanent --add-service=nfs
    sudo -n firewall-cmd --permanent --add-service=rpc-bind
    sudo -n firewall-cmd --permanent --add-service=mountd
    sudo -n firewall-cmd --reload
  fi
" || { echo "FAILED setting up NFS on $mainhost"; exit 1; }

# ── Step 3: Mount NFS shares on all compute nodes ────────────────────────────
# (This is the section missing from the truncated Ubuntu original.)
echo "== Step 3: Mounting NFS on compute nodes =="

HOME_MOUNT="$LOGIN:/home /home nfs defaults,_netdev,hard,timeo=600,retrans=2 0 0"
HAYDEAN_MOUNT="$mainhost:/haydean /haydean nfs defaults,_netdev,hard,timeo=600,retrans=2 0 0"

for host in "${nodes[@]}"; do
  host="${host//$'\r'/}"
  [ -z "$host" ] && continue
  echo "[$host] configuring mounts"

  # The node that serves /haydean must NOT mount it over NFS from itself.
  if [[ "$host" == "$mainhost" ]]; then
    MOUNT_HAYDEAN=false
  else
    MOUNT_HAYDEAN=true
  fi

  sshpass -e ssh $SSH_OPTS "$USER@$host" "
    set -e
    sudo -n dnf install -y nfs-utils

    sudo -n mkdir -p /haydean

    # SELinux: without this, sshd cannot read ~/.ssh from an NFS home and
    # key-based login fails with no useful error.
    sudo -n setsebool -P use_nfs_home_dirs 1 || true

    # Idempotent fstab entries — remove stale then re-add
    sudo -n sed -i '\|:/home |d' /etc/fstab
    sudo -n sed -i '\|:/haydean |d' /etc/fstab

    echo '$HOME_MOUNT' | sudo -n tee -a /etc/fstab > /dev/null
    if [ '$MOUNT_HAYDEAN' = 'true' ]; then
      echo '$HAYDEAN_MOUNT' | sudo -n tee -a /etc/fstab > /dev/null
    fi

    sudo -n systemctl daemon-reload

    # Mount only what isn't already mounted
    if ! mountpoint -q /home; then
      sudo -n mount /home && echo '  mounted /home' || echo '  FAILED mounting /home'
    else
      echo '  /home already mounted'
    fi

    if [ '$MOUNT_HAYDEAN' = 'true' ]; then
      if ! mountpoint -q /haydean; then
        sudo -n mount /haydean && echo '  mounted /haydean' || echo '  FAILED mounting /haydean'
      else
        echo '  /haydean already mounted'
      fi
    else
      echo '  /haydean is local on this node (NFS server) — not mounting'
    fi
  " || echo "FAILED: $host"
done

# ── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "== Step 4: Verify =="
for host in "${nodes[@]}"; do
  host="${host//$'\r'/}"
  [ -z "$host" ] && continue
  echo "[$host]"
  sshpass -e ssh $SSH_OPTS "$USER@$host" \
    "df -hT /home /haydean 2>/dev/null | grep -vE '^Filesystem' || echo '  none'"
done

echo "== DONE =="
