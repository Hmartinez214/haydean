# mdtest storage benchmark on the haydean cluster — runbook

Log of every meaningful action taken to get `mdtest` running against the
cluster's shared filesystems, in the order it needs to be repeated.

Written 2026-08-11. Target: `haydeanlogin` (login/controller) + `haydean1-4`
(compute, partition `no_dinos`).

---

## 0. Quick start (everything is already built)

The build lives on NFS at `/home/hpcadmin/storagebenchmarks/opt/bin`, so all
compute nodes already see it. To just re-run the benchmark:

```bash
cd /home/hpcadmin/storagebenchmarks && ./submit_sweep.sh && python3 parse_results.py
```

To rebuild from nothing, run sections 2 → 5 in order.

---

## 1. What the cluster looks like (discovered, not assumed)

Worth re-checking before trusting any numbers, since the storage topology is
what the results are actually measuring.

```bash
sinfo                                   # partitions / node states
df -hT                                  # local filesystems
sudo exportfs -v                        # what this node serves over NFS
lsblk -d -o NAME,SIZE,ROTA,MODEL        # ROTA=1 means spinning disk
cat /sys/class/net/<iface>/speed        # link speed
```

Findings:

| | `/home` | `/haydean` |
|---|---|---|
| Served by | `haydeanlogin` | `haydean1` |
| Backing device | Hitachi HUA72202, **ROTA=1 (7200rpm HDD)** | Intel SSDSC2KB24, **ROTA=0 (SSD)** |
| Size | 1.8T ext4 | 218G ext4 |
| Export opts | `rw,sync,no_subtree_check,no_root_squash` | same |
| Mounted on | all of haydean1-4 | haydean2-4 only — **local dir on haydean1** |
| Network | 1 GbE (`eno1`) | 1 GbE (`enp1s0`) |

Two consequences that shape the benchmark design:

- `sync` on both exports means every metadata create is a synchronous commit.
  On the HDD that is one seek+rotation per op — this is the dominant effect in
  the results, not anything about NFS itself.
- **haydean1 is the `/haydean` server and accesses it as a local directory**,
  not over NFS. Including it as a client mixes local and NFS access in one
  number. All `/haydean` runs therefore use `--exclude=haydean1`, and a matching
  3-node `/home` sweep exists so the two can be compared apples-to-apples.

Incidental observation, unrelated to performance: both exports use `*`
(any host) with `no_root_squash`, which does not match what `~/nfs.sh` intends
to write (`$SUBNET(...root_squash)`). The live files predate the current script.

---

## 2. Install dependencies on every node

`mdtest` needs MPI at both build and run time, on all nodes.

```bash
cd /home/hpcadmin/storagebenchmarks && ./install_deps.sh
```

`install_deps.sh` installs on the login node and haydean1-4 in parallel:
`build-essential automake autoconf libtool git openmpi-bin libopenmpi-dev`.

**Also required, and easy to miss:**

```bash
sudo apt-get install -y pkg-config      # on every node
```

Without it IOR's `./bootstrap` dies with a misleading error (see Pitfall C).

Ubuntu 26.04 ships OpenMPI 5.0.10 / GCC 15.2.0.

---

## 3. Build IOR (provides `ior`, `mdtest`, `md-workbench`)

Build **on a compute node**, installing into the NFS-shared path so every node
sees identical binaries — no per-node install needed.

```bash
git clone --depth 1 https://github.com/hpc/ior.git \
  /home/hpcadmin/storagebenchmarks/src/ior
ssh hpcadmin@haydean1.local /home/hpcadmin/storagebenchmarks/build_ior.sh
```

`build_ior.sh` runs `./bootstrap`, then
`./configure --prefix=/home/hpcadmin/storagebenchmarks/opt CC=mpicc MPICC=mpicc`,
then `make -j && make install`. Result: `opt/bin/{ior,mdtest,md-workbench}`
(mdtest 4.1.0+dev).

Note the login node has internet access; clone there, build on the compute node.

---

## 4. Verify MPI before benchmarking

Do not skip this — every failure mode below produces an opaque error once it is
buried inside a benchmark run.

```bash
# single node
ssh hpcadmin@haydean1.local /home/hpcadmin/storagebenchmarks/mpi_smoke.sh

# multi-node over ssh (absolute path is mandatory, see Pitfall B)
ssh hpcadmin@haydean1.local 'mpirun \
  --host haydean1.local:2,haydean2.local:2,haydean3.local:2,haydean4.local:2 \
  -n 8 /home/hpcadmin/storagebenchmarks/hello_bin'

# under Slurm
sbatch slurm_mpi_smoke.sbatch

# max ranks/node (must print 12, see Pitfall D)
ssh hpcadmin@haydean1.local 'mpirun --use-hwthread-cpus --bind-to none -n 12 \
  /home/hpcadmin/storagebenchmarks/hello_bin'
```

All four must pass. Passwordless ssh already works both login→compute and
compute→compute (the full mesh is required for MPI wireup).

---

## 5. Run the sweep

```bash
./submit_sweep.sh
```

Submits 15 jobs. Design decisions baked in:

- **`--dependency=singleton` + shared `--job-name=mdchain`** so Slurm runs
  exactly one at a time. This is essential: concurrent jobs would contend for
  the same NFS server and silently corrupt every number.
- `--exclusive` so no other job shares a node with a run.
- Fixed 4 (or 3) nodes, varying ranks/node — a clean client-concurrency sweep
  rather than mixing node count and rank count.
- `NFILES=64` per rank, `ITER=2` (two iterations gives a std-dev column).
- `-N <ranks-per-node>` strides the stat phase so a rank stats files created on
  a *different* node, defeating client-side metadata caching on NFS.
- Targets are wiped after each run.

| Sweep | Target | Nodes | Ranks |
|---|---|---|---|
| 1 | `/home` | 4 | 1, 4, 8, 16, 32, 48 |
| 2 | `/haydean` | 3 (haydean1 excluded) | 3, 6, 12, 24, 36 |
| 3 | `/home` | 3 (same 3 clients) | 12, 36 |
| 4 | `/home` with `-u` (unique dir/rank) | 4 | 16 |
| baseline | node-local `/tmp` ext4 | 1 | 4 |

Monitor and collect:

```bash
squeue -u hpcadmin -n mdchain
python3 parse_results.py
```

Raw per-run output lands in `results/<tag>_n<ranks>.txt`, Slurm logs in
`logs/mdtest-<jobid>.out`.

---

## 6. Pitfalls hit, and the fixes

### A. OpenMPI 5 on Ubuntu 26.04 has no help files
Any MPI error prints `Sorry! You were supposed to get help about: <topic>` with
no detail, because `/usr/lib/x86_64-linux-gnu/{pmix2,prrte3}/share/.../help-*.txt`
are missing from the packages. Even `mpirun --version` fails this way.
**The topic name after "help about:" is the actual error** — read that. The
three seen here were `prun:exe-not-accessible`, `allocation-overload`, and
`prun:proc-aborted-strsignal`.

### B. `ssh host 'cmd'` starts in `$HOME`, not your working directory
Relative paths silently break: `mpicc hello.c` and `mpirun -n 4 ./hello_bin`
both fail even though the file is plainly visible over NFS. Use absolute paths
in every remote command, or wrap the work in a script that `cd`s first (which
is what `mpi_smoke.sh` and `build_ior.sh` do). Cost me several confused retries.

### C. IOR `./bootstrap` fails without `pkg-config`
```
configure.ac:91: error: possibly undefined macro: AC_DEFINE
configure.ac:403: error: possibly undefined macro: AC_SUBST
```
The error points at `AC_DEFINE`, but the real cause is `PKG_CHECK_MODULES` on
line 403 — `pkg-config` was not installed, so `/usr/share/aclocal/pkg.m4` was
missing and autoconf left the macro unexpanded. Fix: `apt install pkg-config`.

### D. PRRTE aborts above 6 ranks/node (`allocation-overload`)
The nodes are 6 cores × 2 threads = 12 CPUs, and Slurm advertises `CPUTot=12`.
PRRTE counts only **physical cores** as slots, so any run with >6 ranks/node
aborts. This silently killed the first attempt at the 32-, 48-, 24- and 36-rank
runs, while every run at ≤6 ranks/node succeeded.

Fix, now in `run_mdtest.sbatch`:
```bash
mpirun --use-hwthread-cpus --bind-to none -n "$SLURM_NTASKS" ...
```
`--use-hwthread-cpus` makes slots = 12/node, matching Slurm. `--bind-to none`
avoids binding many ranks onto few hwthreads; harmless here because a metadata
benchmark is I/O bound, not CPU bound.

Note `sbatch` snapshots the script at submit time, so fixing the file does
**not** repair already-queued jobs — they must be resubmitted.

### E. `mdtest` "File read" is not a read test here
mdtest warns `Read bytes is 0, thus, a read test will actually just open/close`.
With no `-w`/`-e` the files are zero-byte, so the "File read" row measures
open/close and is wildly noisy (68 to 865,000 ops/s across runs). **Ignore that
row.** This sweep is deliberately pure-metadata; for bandwidth use `ior`, or add
`-w <bytes>` to mdtest.

### G. `--exclusive` does NOT protect the NFS server — check it before running
This invalidated an entire sweep. `--exclusive` reserves *compute nodes*, but
`/home` is served by `haydeanlogin`, which is a **shared interactive login box**.
During the first sweep it had 10 users logged in (two VS Code remote sessions,
which write to `~/.vscode-server` continuously), plus `java`, `mongod` and
`mariadbd`, with the `/home` HDD pegged at 92–98% utilisation. Every `/home`
number was measured against that background load.

`/haydean` is unaffected — it is served by `haydean1`, a compute node with no
interactive users, and it is not mounted on the login node at all.

**Always run this before trusting a `/home` result, and re-check after:**
```bash
who                                    # expect ~1 (you)
uptime                                 # expect low load
iostat -x sda 1 3                      # expect %util near 0 at idle
squeue -a                              # expect no other users' jobs
```
There is no way to reserve the login node through Slurm, so the only options are
to benchmark `/home` when the box is genuinely quiet, or to treat `/home`
figures as a *lower bound* rather than a measurement.

### F. Single-rank stat numbers are client cache, not server speed
The 1-rank `/home` run reports ~168k dir-stat/s and ~193k file-stat/s. That is
the local NFS client cache. The `-N` stride only defeats caching once there are
multiple ranks, so treat 1-rank stat figures as a cache measurement.

---

## 7. Files

| File | Purpose |
|---|---|
| `install_deps.sh` | Parallel apt install across login + haydean1-4 |
| `build_ior.sh` | bootstrap/configure/make/install IOR into `opt/` |
| `hello.c`, `mpi_smoke.sh` | Minimal MPI rank/hostname check |
| `slurm_mpi_smoke.sbatch` | Same check under a Slurm allocation |
| `run_mdtest.sbatch` | Parameterized single mdtest run (`TARGET`, `NFILES`, `ITER`, `TAG`, `EXTRA`) |
| `submit_sweep.sh` | Submits the serialized 15-job sweep |
| `parse_results.py` | Parses `results/*.txt` into ops/sec comparison tables |
| `results/`, `logs/`, `opt/`, `src/` | Output, Slurm logs, install prefix, source |
