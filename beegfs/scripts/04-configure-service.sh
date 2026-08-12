#!/bin/bash
# Configure and start one BeeGFS service on the node this runs on.
#
#   usage: 04-configure-service.sh {mgmtd|meta|storage|client}
#
# Idempotent: re-running rewrites the same settings and restarts the service.
# Reads cluster.env from the same directory.
set -euo pipefail

ROLE="${1:-}"
case "$ROLE" in
  mgmtd|meta|storage|client) ;;
  *) echo "usage: $0 {mgmtd|meta|storage|client}" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/cluster.env"

HOST="$(hostname -s)"

# Work out which interface faces the cluster. Every node here also runs a VPN
# interface, and BeeGFS advertises all interfaces by default, so without this
# the nodes discover each other over the VPN and every storage operation gets
# encrypted and routed the long way round.
NIC="$(ip -o -4 addr show | awk -v net="$CLUSTER_SUBNET" '$4 ~ net {print $2; exit}')"
if [ -z "$NIC" ]; then
  echo "$HOST: no interface on $CLUSTER_SUBNET, refusing to configure $ROLE" >&2
  exit 1
fi

# Restrict BeeGFS to that interface. The daemons read this file at startup.
echo "$NIC" | sudo tee /etc/beegfs/connInterfaces.conf >/dev/null

# set_conf <file> <key> <value>   rewrites "key = value" in a BeeGFS .conf
set_conf() {
  sudo sed -i "s|^$2[[:space:]]*=.*|$2 = $3|" "$1"
}

case "$ROLE" in
  mgmtd)
    sudo mkdir -p /var/lib/beegfs
    # The shipped TOML is entirely commented out, so append live settings.
    # Strip any block we wrote previously to stay idempotent.
    sudo sed -i '/^### managed by 04-configure-service.sh/,$d' /etc/beegfs/beegfs-mgmtd.toml
    sudo tee -a /etc/beegfs/beegfs-mgmtd.toml >/dev/null <<EOF
### managed by 04-configure-service.sh
db-file = "/var/lib/beegfs/mgmtd.sqlite"
# No PKI on this cluster, and gRPC insists on TLS unless told otherwise.
tls-disable = true
# Report only the cluster-facing interface to other nodes.
interfaces = ["$NIC"]
EOF
    # BeeGFS 8 will not start against a database that does not exist yet, and
    # --init refuses to overwrite an existing one, so guard it.
    if [ ! -f /var/lib/beegfs/mgmtd.sqlite ]; then
      sudo /opt/beegfs/sbin/beegfs-mgmtd --init
    fi
    ;;

  meta)
    sudo mkdir -p "$META_DIR"
    set_conf /etc/beegfs/beegfs-meta.conf sysMgmtdHost "$MGMTD_HOST"
    set_conf /etc/beegfs/beegfs-meta.conf storeMetaDirectory "$META_DIR"
    set_conf /etc/beegfs/beegfs-meta.conf connInterfacesFile /etc/beegfs/connInterfaces.conf
    ;;

  storage)
    if ! mountpoint -q "$STORAGE_DIR"; then
      echo "$HOST: $STORAGE_DIR is not a mountpoint, run 03-prepare-storage.sh first" >&2
      exit 1
    fi
    set_conf /etc/beegfs/beegfs-storage.conf sysMgmtdHost "$MGMTD_HOST"
    set_conf /etc/beegfs/beegfs-storage.conf storeStorageDirectory "$STORAGE_DIR"
    set_conf /etc/beegfs/beegfs-storage.conf connInterfacesFile /etc/beegfs/connInterfaces.conf
    ;;

  client)
    sudo mkdir -p "$BEEGFS_MOUNT"
    set_conf /etc/beegfs/beegfs-client.conf sysMgmtdHost "$MGMTD_HOST"
    set_conf /etc/beegfs/beegfs-client.conf connInterfacesFile /etc/beegfs/connInterfaces.conf

    # beegfs-client-dkms ships /sbin/mount.beegfs and no systemd unit, so the
    # mount goes in fstab like any other filesystem. _netdev holds boot until
    # the network is up, otherwise the mount races the interface.
    if ! grep -q " $BEEGFS_MOUNT beegfs " /etc/fstab; then
      echo "beegfs_nodev $BEEGFS_MOUNT beegfs defaults,cfgFile=/etc/beegfs/beegfs-client.conf,_netdev 0 0" \
        | sudo tee -a /etc/fstab >/dev/null
    fi
    sudo systemctl daemon-reload
    mountpoint -q "$BEEGFS_MOUNT" || sudo mount "$BEEGFS_MOUNT"

    if mountpoint -q "$BEEGFS_MOUNT"; then
      echo "$HOST: beegfs mounted at $BEEGFS_MOUNT via $NIC"
      exit 0
    fi
    echo "$HOST: beegfs mount FAILED"
    sudo dmesg | grep -i beegfs | tail -10
    exit 1
    ;;
esac

# Do not let a failed start abort the script under set -e, or the diagnostic
# block below never runs and the failure is silent.
sudo systemctl enable --now "beegfs-$ROLE" >/dev/null 2>&1 || true
sleep 2

if systemctl is-active --quiet "beegfs-$ROLE"; then
  echo "$HOST: beegfs-$ROLE active on $NIC"
else
  echo "$HOST: beegfs-$ROLE FAILED"
  sudo journalctl -u "beegfs-$ROLE" -n 15 --no-pager
  exit 1
fi
