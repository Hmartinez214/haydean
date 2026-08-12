#!/bin/bash
# Rocky port of passwordless.sh
#
# Changes from the Ubuntu original:
#   None functionally — sudoers.d works identically on Rocky.
#   Added `visudo -c` validation before installing the file: a malformed
#   sudoers drop-in locks you out of sudo entirely, and on Rocky you cannot
#   fall back to `sudo` from another admin group as easily because the admin
#   group is `wheel`, not `sudo`.

USER="hpcadmin"
CLUSTER_FILE="cluster.txt"
PASS_FILE="PASSWORD.txt"

PASS="$(tr -d '\r\n' < "$PASS_FILE")"

mapfile -t nodes < "$CLUSTER_FILE"

for h in "${nodes[@]}"; do
  h="${h//$'\r'/}"
  [ -z "$h" ] && continue

  echo "== $h =="

  sshpass -p "$PASS" ssh -tt -o StrictHostKeyChecking=no "$USER@$h" "
    echo '$PASS' | sudo -S bash -c '
      echo \"hpcadmin ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/hpcadmin.tmp &&
      chmod 440 /etc/sudoers.d/hpcadmin.tmp &&
      if visudo -c -f /etc/sudoers.d/hpcadmin.tmp; then
        mv /etc/sudoers.d/hpcadmin.tmp /etc/sudoers.d/hpcadmin
      else
        rm -f /etc/sudoers.d/hpcadmin.tmp
        echo \"ERROR: sudoers validation failed on \$(hostname)\"
        exit 1
      fi
    '
  "
done
