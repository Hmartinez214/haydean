#!/bin/bash
# Rocky port of update_hosts.sh — reviewed, NO CHANGES NEEDED.
# Contains no package-manager, group, firewall or SELinux dependencies.
# sync-hosts.sh — run on all nodes via cron or systemd timer

CLUSTER_FILE="cluster.txt"
mapfile -t NODES < "$CLUSTER_FILE"
nodes+=("($hostname).local")

for node in "${NODES[@]}"; do
    ip=$(avahi-resolve-host-name "${node}" 2>/dev/null | awk '{print $2}')
    if [[ -n "$ip" ]]; then
        # Remove old entry, add fresh one
        sed -i "/[[:space:]]${node}$/d" /etc/hosts
        echo "$ip  $node" >> /etc/hosts
    fi
done
