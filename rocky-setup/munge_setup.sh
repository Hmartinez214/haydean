#!/bin/bash
# Rocky port of munge_setup.sh
#
# Changes from the Ubuntu original:
#   apt-get                → dnf
#   munge libmunge2        → munge munge-libs   (from EPEL — run 00_repos.sh first)
#   Added munge-devel on the login node: required later to build the Slurm RPMs.
#   Key generation switched to `mungekey` where available (the supported tool on
#     current munge); falls back to the original dd-from-urandom.
#   Added /var/log/munge and /var/lib/munge ownership fixes — the Rocky package
#     creates these but a mismatched pre-created munge UID (see 00_repos.sh)
#     leaves them owned by the wrong id and munged refuses to start.
#   Key is generated into /etc/munge on the login node, not /tmp. On Rocky
#     /tmp is often a tmpfs and PrivateTmp applies to services; keeping a
#     credential in a world-readable /tmp was also a poor idea on Ubuntu.

set -uo pipefail

USER="hpcadmin"
CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"

export SSHPASS="$(tr -d '\r\n' < "$PASS_FILE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

MUNGE_KEY="/etc/munge/munge.key"
STAGE_KEY="$(mktemp -u /tmp/munge.key.XXXXXX)"

echo "== Step 0: Install munge locally =="
sudo dnf install -y munge munge-libs munge-devel

sudo mkdir -p /etc/munge /var/log/munge /var/lib/munge /run/munge
sudo chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge /run/munge
sudo chmod 700 /etc/munge /var/log/munge /var/lib/munge

echo "== Step 1: Generate munge key (on login node) =="
if [ ! -f "$MUNGE_KEY" ]; then
  if command -v mungekey &>/dev/null; then
    sudo mungekey --create --keyfile "$MUNGE_KEY"
  else
    sudo dd if=/dev/urandom bs=1 count=1024 of="$MUNGE_KEY"
  fi
  sudo chown munge:munge "$MUNGE_KEY"
  sudo chmod 400 "$MUNGE_KEY"
  echo "  created $MUNGE_KEY"
else
  echo "  $MUNGE_KEY already exists, reusing"
fi

sudo systemctl enable --now munge

# Stage a readable copy for scp, removed at the end.
sudo cp "$MUNGE_KEY" "$STAGE_KEY"
sudo chown "$(id -u):$(id -g)" "$STAGE_KEY"
sudo chmod 400 "$STAGE_KEY"

echo "== Step 2: Distribute munge key to nodes =="

while IFS= read -r host || [ -n "$host" ]; do
  host=$(echo "$host" | tr -d '\r')
  [ -z "$host" ] && continue

  echo "[$host] installing munge"

  sshpass -e ssh $SSH_OPTS hpcadmin@"$host" "
    sudo -n dnf install -y munge munge-libs

    sudo -n systemctl stop munge || true
    sudo -n rm -rf /run/munge/*
    sudo -n mkdir -p /etc/munge /var/log/munge /var/lib/munge
    sudo -n chown -R munge:munge /etc/munge /var/log/munge /var/lib/munge
    sudo -n chmod 700 /etc/munge /var/log/munge /var/lib/munge
  "

  # copy key
  sshpass -e scp $SSH_OPTS "$STAGE_KEY" hpcadmin@"$host":/tmp/munge.key

  sshpass -e ssh $SSH_OPTS hpcadmin@"$host" "
    sudo -n mv /tmp/munge.key /etc/munge/munge.key
    sudo -n chown munge:munge /etc/munge/munge.key
    sudo -n chmod 400 /etc/munge/munge.key

    sudo -n systemctl enable munge
    sudo -n systemctl restart munge
  "

done < "$CLUSTER_FILE"

rm -f "$STAGE_KEY"

echo "== Step 3: Verify munge =="

# Local check first
munge -n | unmunge > /dev/null && echo "[login] OK" || echo "[login] FAILED"

for host in $(cat "$CLUSTER_FILE"); do
  host=$(echo "$host" | tr -d '\r')
  echo -n "[$host] "
  sshpass -e ssh $SSH_OPTS hpcadmin@"$host" "munge -n | unmunge > /dev/null" \
    && echo "OK" || echo "FAILED"
done

# Cross-node check: a credential made on the login node must verify on a node.
echo "== Step 4: Cross-node credential check =="
CRED=$(munge -n)
for host in $(cat "$CLUSTER_FILE"); do
  host=$(echo "$host" | tr -d '\r')
  echo -n "[$host] decoding login-node credential: "
  echo "$CRED" | sshpass -e ssh $SSH_OPTS hpcadmin@"$host" "unmunge > /dev/null" \
    && echo "OK" || echo "FAILED — keys do not match"
done

echo "== DONE =="
