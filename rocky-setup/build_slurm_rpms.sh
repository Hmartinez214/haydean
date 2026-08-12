#!/bin/bash
# build_slurm_rpms.sh — Rocky Linux only. No Ubuntu equivalent.
#
# WHY THIS EXISTS:
# On Ubuntu, setup_slurm.sh could just `apt-get install slurmctld slurmd
# slurm-client`. Rocky has no such packages — Slurm is not in base, AppStream,
# or EPEL. The supported options are:
#   (a) build RPMs from SchedMD's release tarball  <- what this does
#   (b) add the OpenHPC repo and use its slurm-*-ohpc packages
# (a) is used here because it keeps the cluster self-contained and pins an
# exact version, which matters when slurmctld/slurmd must match.
#
# Build once on the login node; the RPMs are written into /home (shared over
# NFS/BeeGFS) so every node installs the identical build.
#
# Run AFTER 00_repos.sh (needs EPEL + CRB) and AFTER nfs.sh (needs shared /home).

set -euo pipefail

# Check https://download.schedmd.com/slurm/ and set this to the current release.
SLURM_VERSION="${SLURM_VERSION:-25.05.1}"

RPM_SHARE="/home/hpcadmin/slurm-rpms"
BUILD_DIR="$HOME/rpmbuild"

echo "== Installing build dependencies =="
sudo dnf groupinstall -y "Development Tools"
sudo dnf install -y \
  rpm-build rpmdevtools \
  munge-devel munge-libs \
  pam-devel readline-devel openssl-devel \
  perl-ExtUtils-MakeMaker perl-Switch \
  python3 \
  mariadb-devel \
  numactl-devel hwloc-devel lua-devel \
  dbus-devel json-c-devel libyaml-devel libjwt-devel \
  http-parser-devel

echo "== Fetching Slurm $SLURM_VERSION =="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
TARBALL="slurm-${SLURM_VERSION}.tar.bz2"
if [[ ! -f "$TARBALL" ]]; then
  curl -fSLO "https://download.schedmd.com/slurm/${TARBALL}"
fi

echo "== Building RPMs (this takes a few minutes) =="
# --with mysql   : builds slurmdbd's accounting storage plugin (slurm_db.sh needs it)
# --without man2html : man2html is not packaged on Rocky and only affects HTML docs
rpmbuild -ta "$TARBALL" \
  --define '_with_mysql 1' \
  --define '_without_man2html 1'

echo "== Publishing RPMs to $RPM_SHARE =="
mkdir -p "$RPM_SHARE"
cp "$BUILD_DIR"/RPMS/x86_64/*.rpm "$RPM_SHARE/"
chmod 644 "$RPM_SHARE"/*.rpm

echo ""
echo "== Built RPMs =="
ls -1 "$RPM_SHARE"
echo ""
echo "Now run ./setup_slurm.sh — it installs from $RPM_SHARE."
