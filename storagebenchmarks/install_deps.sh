#!/bin/bash
# Install OpenMPI + build toolchain on login node and all compute nodes.
set -u

PKGS="build-essential automake autoconf libtool git openmpi-bin libopenmpi-dev"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"
LOG=/home/hpcadmin/storagebenchmarks/logs
mkdir -p "$LOG"

install_local() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS
}

echo "== login node (haydeanlogin) =="
install_local > "$LOG/install_haydeanlogin.log" 2>&1 &
pids=("$!")
names=("haydeanlogin")

for h in haydean1 haydean2 haydean3 haydean4; do
  echo "== $h =="
  ssh $SSH_OPTS "hpcadmin@$h.local" \
    "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
     sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS" \
    > "$LOG/install_$h.log" 2>&1 &
  pids+=("$!")
  names+=("$h")
done

fail=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "OK   ${names[$i]}"
  else
    echo "FAIL ${names[$i]} (see $LOG/install_${names[$i]}.log)"
    fail=1
  fi
done

echo "== verifying mpirun on every node =="
mpirun --version 2>&1 | head -1 | sed 's/^/haydeanlogin: /'
for h in haydean1 haydean2 haydean3 haydean4; do
  ssh $SSH_OPTS "hpcadmin@$h.local" "mpirun --version 2>&1 | head -1" | sed "s/^/$h: /"
done

exit $fail
