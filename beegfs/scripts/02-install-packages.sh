#!/bin/bash
# Install BeeGFS packages appropriate to this node's role.
# Adds packages only; nothing is removed.
#
# Edit the three lists below to match your cluster's hostnames, then run this
# on every node. Each node works out its own role from its short hostname.
set -euo pipefail

MGMT_NODES="login"
META_NODES="node1 node2"
STORAGE_NODES="node1 node2 node3 node4"
CLIENT_NODES="login node1 node2 node3 node4"

HOST="$(hostname -s)"
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PKGS=""
in_list "$HOST" "$MGMT_NODES"    && PKGS="$PKGS beegfs-mgmtd"
in_list "$HOST" "$META_NODES"    && PKGS="$PKGS beegfs-meta"
in_list "$HOST" "$STORAGE_NODES" && PKGS="$PKGS beegfs-storage"
in_list "$HOST" "$CLIENT_NODES"  && PKGS="$PKGS beegfs-client-dkms beegfs-utils"

if [ -z "$PKGS" ]; then
  echo "$HOST: no role defined, skipping"
  exit 0
fi

# The client is a DKMS module, so it needs headers for the running kernel.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "linux-headers-$(uname -r)" $PKGS >/dev/null 2>&1

echo "$HOST: installed [$PKGS ]"
