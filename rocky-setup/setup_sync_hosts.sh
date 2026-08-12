#!/bin/bash
# setup_sync_hosts.sh — Rocky port
# Run this on each node to install the sync-hosts systemd timer.
# Expects cluster.txt and controller.txt to be in the same directory as this script.
#
# Changes from the Ubuntu original:
#   Added a check that avahi-resolve-host-name exists — on Rocky it ships in
#     avahi-tools, which is NOT pulled in by the avahi package. Without it this
#     timer runs every 30s and silently writes nothing.
#   Added restorecon on the installed script: SELinux labels files created in
#     /usr/local/sbin as user_home_t if copied from a home directory, and
#     systemd then refuses to execute them.
#   systemd unit files and timer logic are unchanged — identical on both distros.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="/usr/local/etc/slurm-sync"
SYNC_SCRIPT="/usr/local/sbin/sync-hosts.sh"

# ── 0. Rocky preflight ────────────────────────────────────────────────────────
if ! command -v avahi-resolve-host-name &>/dev/null; then
  echo "ERROR: avahi-resolve-host-name not found."
  echo "       Run: sudo dnf install -y avahi-tools nss-mdns   (see avahi.sh)"
  exit 1
fi

# ── 1. Copy cluster/controller files to local storage (not shared FS) ────────
echo "[1/5] Copying node lists to $LOCAL_DIR..."
mkdir -p "$LOCAL_DIR"
cp "$SCRIPT_DIR/cluster.txt"    "$LOCAL_DIR/cluster.txt"
cp "$SCRIPT_DIR/controller.txt" "$LOCAL_DIR/controller.txt"
chmod 644 "$LOCAL_DIR/cluster.txt" "$LOCAL_DIR/controller.txt"

# ── 2. Write sync-hosts.sh to /usr/local/sbin ────────────────────────────────
echo "[2/5] Installing sync-hosts.sh to $SYNC_SCRIPT..."
cat > "$SYNC_SCRIPT" << 'EOF'
#!/bin/bash
# sync-hosts.sh — resolve .local mDNS names and write short names to /etc/hosts
# Node lists are read from LOCAL_DIR, not the shared FS, to be safe during boot.

LOCAL_DIR="/usr/local/etc/slurm-sync"
CLUSTER_FILE="$LOCAL_DIR/cluster.txt"
CONTROLLER_FILE="$LOCAL_DIR/controller.txt"

if [[ ! -f "$CLUSTER_FILE" || ! -f "$CONTROLLER_FILE" ]]; then
    echo "sync-hosts: node list files missing in $LOCAL_DIR, skipping." >&2
    exit 1
fi

mapfile -t NODES < <(cat "$CLUSTER_FILE" "$CONTROLLER_FILE")

for node in "${NODES[@]}"; do
    # Accept entries already with or without .local
    bare="${node%.local}"
    fqdn="${bare}.local"

    ip=$(avahi-resolve-host-name -4 "$fqdn" 2>/dev/null | awk '{print $2}')
    if [[ -n "$ip" ]]; then
        # Remove any existing entries for this host (short or .local form)
        sed -i -E "/[[:space:]]${bare}([[:space:]]|$)/d;/[[:space:]]${fqdn}([[:space:]]|$)/d" /etc/hosts
        echo "$ip  $bare  $fqdn" >> /etc/hosts
    fi
done
EOF
chmod 755 "$SYNC_SCRIPT"

# ── 3. Fix SELinux label on the installed script ─────────────────────────────
echo "[3/5] Restoring SELinux context on $SYNC_SCRIPT..."
if command -v restorecon &>/dev/null; then
  restorecon -v "$SYNC_SCRIPT" || true
fi

# ── 4. Write systemd unit files ───────────────────────────────────────────────
echo "[4/5] Installing systemd unit files..."

cat > /etc/systemd/system/sync-hosts.service << 'EOF'
[Unit]
Description=Sync mDNS hostnames into /etc/hosts
After=network.target avahi-daemon.service
Wants=avahi-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-hosts.sh
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/sync-hosts.timer << 'EOF'
[Unit]
Description=Run sync-hosts every 30 seconds
After=network.target avahi-daemon.service

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

# ── 5. Enable and start the timer ────────────────────────────────────────────
echo "[5/5] Enabling and starting sync-hosts.timer..."
systemctl daemon-reload
systemctl enable --now sync-hosts.timer

echo ""
echo "Done. Timer status:"
systemctl status sync-hosts.timer --no-pager
echo ""
echo "Run 'journalctl -u sync-hosts.service -f' to follow sync logs."
echo "Run 'systemctl list-timers sync-hosts.timer' to check next run time."
