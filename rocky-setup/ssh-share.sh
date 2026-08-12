#!/bin/bash
# Rocky port of ssh-share.sh — reviewed, NO CHANGES NEEDED.
# Contains no package-manager, group, firewall or SELinux dependencies.
USER="hpcadmin"
CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"

WORKDIR=$(mktemp -d)
KEY_BUNDLE="$WORKDIR/authorized_keys_bundle"
> "$KEY_BUNDLE"

echo "== Step 0: sanity check cluster file =="
if [ ! -f "$CLUSTER_FILE" ]; then
  echo "ERROR: cluster.txt not found"
  exit 1
fi

# Strip carriage returns at load time, add login node once
mapfile -t nodes < <(tr -d '\r' < "$CLUSTER_FILE")
nodes+=("$(hostname).local")

echo "Nodes:"
printf '  %s\n' "${nodes[@]}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "== Step 1: Ensure ssh keys exist on all nodes =="
for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  echo "[$host] checking key"
  sshpass -e ssh $SSH_OPTS "$USER@$host" "
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    if [ ! -f ~/.ssh/id_ed25519 ]; then
      ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
    fi
  " || echo "FAILED: $host"
done

echo "== Step 2: Collect public keys =="
for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  echo "[$host] collecting key" >&2
  result=$(sshpass -e ssh $SSH_OPTS "$USER@$host" "cat ~/.ssh/id_ed25519.pub" 2>&1)
  if [[ "$result" == ssh-ed25519* || "$result" == ssh-rsa* ]]; then
    echo "$result"
  else
    echo "FAILED [$host]: $result" >&2
  fi
done | sort -u > "$KEY_BUNDLE"

echo "== Step 3: Validate bundle =="
echo "Total keys collected:"
wc -l "$KEY_BUNDLE"
cat "$KEY_BUNDLE"

if [ ! -s "$KEY_BUNDLE" ]; then
  echo "ERROR: key bundle is empty"
  exit 1
fi

echo "== Step 4: Distribute authorized_keys =="
for host in "${nodes[@]}"; do
  [ -z "$host" ] && continue
  echo "[$host] installing authorized_keys"
  cat "$KEY_BUNDLE" | sshpass -e ssh $SSH_OPTS "$USER@$host" "
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    cat > ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
  " || echo "FAILED: $host"
done

echo "== DONE: SSH mesh complete =="
rm -rf "$WORKDIR"
