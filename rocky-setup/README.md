# haydean cluster setup — Rocky Linux port

Rocky Linux adaptation of the Ubuntu setup scripts in `/home/hpcadmin`.
**The originals are untouched.** This directory is a parallel copy.

Scope: a like-for-like OS port only. Storage is still NFS here — see
[Where BeeGFS slots in](#where-beegfs-slots-in) at the bottom.

Nothing in here has been executed. It is written against Rocky 9/10 conventions
and needs a test run on the rebuilt cluster.

---

## Run order

Order matters more than it did on Ubuntu, because Slurm now has to be compiled
before it can be installed.

| # | Script | Where | Notes |
|---|---|---|---|
| 1 | `00_repos.sh` | login | **New.** EPEL + CRB repos, pinned munge/slurm UIDs |
| 2 | `avahi.sh` | every node | mDNS `.local` resolution |
| 3 | `passwordless.sh` | login | NOPASSWD sudo for hpcadmin |
| 4 | `ssh-share.sh` | login | Builds the ssh key mesh |
| 5 | `setup_sync_hosts.sh` | every node | `/etc/hosts` sync timer |
| 6 | `nfs.sh` | login | Shared `/home` + `/haydean` |
| 7 | `munge_setup.sh` | login | Auth key, distributed to all nodes |
| 8 | `build_slurm_rpms.sh` | login | **New.** Compiles Slurm RPMs |
| 9 | `generate_slurm_conf.sh` | login | Writes `slurm.conf` |
| 10 | `setup_slurm.sh` | login | Installs slurmctld/slurmd |
| 11 | `slurm_db.sh` | login | MariaDB + slurmdbd accounting |

Then `add_user.sh`, `remove_user.sh`, `sync_password.sh`, `run_all.sh` as needed.

`PASSWORD.txt` is **not** copied here — put your own in this directory before
running anything, or symlink it: `ln -s ../PASSWORD.txt .`

---

## What changed, and why

### The one that would have bitten silently

**`add_user.sh --admin` — `usermod -aG sudo` → `usermod -aG wheel`.**
Rocky's administrative group is `wheel`; there is no `sudo` group. Ported
verbatim, `--admin` would appear to work but grant nothing.

### Package manager and names

| Ubuntu | Rocky |
|---|---|
| `apt-get install` | `dnf install` |
| `slurmctld`, `slurmd`, `slurm-client` | **not packaged** — see below |
| `munge`, `libmunge2` | `munge`, `munge-libs` (EPEL) |
| `nfs-kernel-server` / `nfs-common` | `nfs-utils` (one package, both roles) |
| `avahi-daemon`, `avahi-utils` | `avahi`, `avahi-tools`, `nss-mdns` |
| `build-essential` | `@"Development Tools"` |
| `mariadb-server` | `mariadb-server` + explicit `systemctl enable --now` |

### Slurm is not packaged for Rocky

Not in base, AppStream, or EPEL. `build_slurm_rpms.sh` compiles RPMs from
SchedMD's tarball and drops them in `/home/hpcadmin/slurm-rpms`, which is on
shared storage so every node installs the identical build. `setup_slurm.sh`
installs from there.

The alternative is the OpenHPC repo (`slurm-*-ohpc` packages). Building from
source was chosen to keep the cluster self-contained and pin an exact version —
slurmctld and slurmd must match.

Set `SLURM_VERSION` in `build_slurm_rpms.sh`; check
<https://download.schedmd.com/slurm/> for the current release before running.

### Things Ubuntu let you ignore

**firewalld is active by default on Rocky.** Ubuntu's ufw was inactive, so the
originals never opened a port. Now handled per-script:

| Port/service | Opened by |
|---|---|
| mDNS 5353/udp | `avahi.sh` |
| nfs, rpc-bind, mountd | `nfs.sh` |
| 6817 slurmctld, 6819 slurmdbd | `setup_slurm.sh`, `slurm_db.sh` |
| 6818 slurmd | `setup_slurm.sh` (on each node) |

If nodes come up `DOWN / Not responding`, check firewalld first.

**SELinux is enforcing by default.** Two places it matters:
- `use_nfs_home_dirs` boolean must be on, or sshd cannot read `~/.ssh` from an
  NFS home and key login fails with nothing useful in the logs. Set in `nfs.sh`.
- Scripts copied into `/usr/local/sbin` from a home directory get mislabelled
  and systemd refuses to execute them. `setup_sync_hosts.sh` now runs
  `restorecon`.

**`/var/run` is cleared on boot.** Slurm pid paths moved to `/run/slurm/`, with a
`tmpfiles.d` rule to recreate the directory. Changed in both
`generate_slurm_conf.sh` and `setup_slurm.sh` — they must agree.

**System UIDs.** `00_repos.sh` pins `munge`=1101 and `slurm`=1102 across all
nodes. On a shared filesystem a mismatched slurm UID produces permission errors
that look like config bugs. Verify with:

```bash
./run_all.sh 'id -u munge; id -u slurm'
```

### Smaller fixes made during the port

- **`nfs.sh` was truncated.** The Ubuntu original ends mid-statement on a bare
  `if` at line 78 — Step 3 (mounting on compute nodes) never existed. Written
  out here, including the case that `haydean1` must not NFS-mount `/haydean`
  from itself. **Compare against the original before assuming behaviour matches.**
- **`/home` mount option `soft` → `hard`.** `soft` risks silent data corruption
  on I/O timeout and is the wrong default for home directories.
- **munge key no longer staged in `/tmp`.** Generated directly into `/etc/munge`,
  with a temporary staging copy removed at the end.
- **`munge_setup.sh` gained a cross-node check** — it now verifies a credential
  minted on the login node actually decodes on each compute node, which is what
  you care about and what the original never tested.
- **`slurm_db.sh` gained InnoDB tuning** (SchedMD's documented minimums) and a
  socket wait loop, because `mysql -e` immediately after `systemctl start` races
  on Rocky.
- **`passwordless.sh` now validates with `visudo -c`** before installing the
  sudoers drop-in. A malformed file locks you out of sudo entirely.

### Reviewed, unchanged

`ssh-share.sh`, `sync_hosts.sh`, `update_hosts.sh` — no package manager, group,
firewall, or SELinux dependencies. Copied verbatim with a note in the header.

---

## Carried over, not fixed

These are pre-existing issues in the Ubuntu scripts. Left alone so this stays a
port rather than a rewrite, but they are worth addressing during the rebuild:

- **`slurm_db.sh` hardcodes `slurmdbpass`** as the accounting DB password, in a
  world-readable script. Change it before real users are on the cluster.
- **`add_user.sh` hardcodes `changeme123`** and does not force a password change
  at first login (`chage -d 0` would).
- **`generate_slurm_conf.sh` sets no `RealMemory`**, so Slurm reports
  `RealMemory=1` per node. Harmless under `CR_Core`, but `--mem` requests cannot
  be honoured, and it will silently break if you ever move to `CR_Core_Memory`.
- **`remove_user.sh` reads `/usr/local/etc/slurm-sync/cluster.txt`**, not the
  local `cluster.txt`. It fails until `setup_sync_hosts.sh` has run.
- **`update_hosts.sh` has a bug**: `nodes+=("($hostname).local")` — wrong
  variable syntax, and it appends to `nodes` while the loop reads `NODES`. The
  line is a no-op. `sync_hosts.sh` supersedes it.

Also note: **do not carry `/etc/shadow` hashes over from the Ubuntu install.**
Ubuntu 26.04 defaults to yescrypt (`$y$`), Rocky to SHA-512 (`$6$`). Copied
hashes produce accounts nobody can log into. Rebuild passwords fresh.

---

## Where BeeGFS slots in

Not implemented — deliberately out of scope for this port.

When you do the cutover, `nfs.sh` is the only storage script that gets replaced.
The rest of the pipeline is storage-agnostic, with these touchpoints:

- `nfs.sh` → a `beegfs.sh` (mgmtd/meta/storage services, client `beegfs-mounts.conf`)
- `add_user.sh` — the SELinux/NFS branch and the `df | grep ':'` NFS test in
  Step 6 both assume NFS and would need adjusting
- `build_slurm_rpms.sh` / `setup_slurm.sh` — publish RPMs to whatever the shared
  mount is; nothing else changes
- Node UID consistency (`00_repos.sh`) matters *more* under BeeGFS, not less

One thing the benchmark work already tells you: `/home` currently sits on a
7200rpm HDD on the login node, and metadata creates are capped around 50 ops/s
by that spindle plus the `sync` export. If BeeGFS metadata targets land on the
same disk, the rebuild will not feel faster. Put metadata on the Intel SSDs.
