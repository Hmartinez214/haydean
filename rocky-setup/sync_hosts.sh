#!/bin/bash
# Rocky port of sync_hosts.sh — reviewed, NO CHANGES NEEDED.
# Contains no package-manager, group, firewall or SELinux dependencies.
# sync-hosts.sh — run on all nodes via cron or systemd timer
CLUSTER_FILE="cluster.txt"
mapfile -t NODES < <(cat "$CLUSTER_FILE" controller.txt)

# printf '%s\n' "${NODES[@]}"

for node in "${NODES[@]}"; do
    ip=$(avahi-resolve-host-name -4 "$node" 2>/dev/null | awk '{print $2}')
    if [[ -n "$ip" ]]; then
        # Remove old entry, add fresh one
        sed -i -E "/[[:space:]]${node%.local}([[:space:]]|$)|[[:space:]]${node}([[:space:]]|$)/d" /etc/hosts
        echo "$ip ${node%.local} $node" >> /etc/hosts
    fi
done
