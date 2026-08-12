#!/bin/bash
# Rocky port of slurm_db.sh
#
# Changes from the Ubuntu original:
#   apt-get install slurmdbd mariadb-server
#     → dnf install of the locally built slurm-slurmdbd RPM + mariadb-server
#   MariaDB must be explicitly enabled/started on Rocky — the Ubuntu package
#     starts it on install, so the original script could go straight to `mysql`.
#   Added a wait loop for the socket; `mysql -e` immediately after `systemctl
#     start` races on Rocky and fails with "Can't connect to local socket".
#   /var/run/slurmdbd.pid → /run/slurm/slurmdbd.pid (Rocky clears /var/run)
#   Added innodb tuning that SchedMD requires for slurmdbd; without it large
#     accounting tables hit "Row size too large" errors later.
#   Password is still the original hardcoded 'slurmdbpass' — see README, this
#     should be changed before the cluster is exposed to real users.

set -euo pipefail

RPM_SHARE="/home/hpcadmin/slurm-rpms"

# ── Install ───────────────────────────────────────────────────────────────────
sudo dnf install -y mariadb-server mariadb
if [[ -d "$RPM_SHARE" ]]; then
  sudo dnf install -y "$RPM_SHARE"/slurm-slurmdbd-*.rpm
else
  echo "ERROR: $RPM_SHARE not found — run ./build_slurm_rpms.sh first"; exit 1
fi

# ── Start MariaDB (Rocky does not auto-start it) ──────────────────────────────
sudo systemctl enable --now mariadb

echo "Waiting for MariaDB socket..."
for i in {1..20}; do
  sudo mysqladmin ping &>/dev/null && break
  [[ $i -eq 20 ]] && { echo "ERROR: MariaDB did not start"; exit 1; }
  sleep 1
done

# InnoDB settings slurmdbd needs (SchedMD documented minimums).
sudo tee /etc/my.cnf.d/slurmdbd.cnf > /dev/null << 'EOF'
[mysqld]
innodb_buffer_pool_size=1024M
innodb_log_file_size=64M
innodb_lock_wait_timeout=900
EOF
sudo systemctl restart mariadb
sleep 2

# ── Set up the database ───────────────────────────────────────────────────────
sudo mysql -e "
  CREATE DATABASE IF NOT EXISTS slurm_acct_db;
  CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY 'slurmdbpass';
  GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
  FLUSH PRIVILEGES;
"

# ── Write slurmdbd.conf ───────────────────────────────────────────────────────
sudo mkdir -p /etc/slurm /var/log/slurm
sudo tee /etc/slurm/slurmdbd.conf << 'EOF'
AuthType=auth/munge
DbdHost=haydeanlogin
DbdPort=6819
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurm/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=slurmdbpass
StorageLoc=slurm_acct_db
EOF

sudo chmod 600 /etc/slurm/slurmdbd.conf
sudo chown slurm:slurm /etc/slurm/slurmdbd.conf
sudo chown -R slurm:slurm /var/log/slurm

echo 'd /run/slurm 0755 slurm slurm -' | sudo tee /etc/tmpfiles.d/slurm.conf > /dev/null
sudo systemd-tmpfiles --create /etc/tmpfiles.d/slurm.conf

if systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --permanent --add-port=6819/tcp
  sudo firewall-cmd --reload
fi

# ── Start slurmdbd first, then slurmctld ──────────────────────────────────────
sudo systemctl enable --now slurmdbd
sleep 3
sudo systemctl restart slurmctld

echo ""
echo "== Verify =="
sudo systemctl is-active slurmdbd && echo "  slurmdbd active" || sudo journalctl -u slurmdbd -n 20 --no-pager
sacctmgr show cluster 2>/dev/null || echo "  sacctmgr not responding yet"
