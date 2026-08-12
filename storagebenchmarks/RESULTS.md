# BeeGFS vs NFS — mdtest metadata benchmark

haydean cluster, measured on an idle cluster after the BeeGFS cutover.
19 runs, mdtest 4.1.0, 64 files/rank, 2 iterations.

Interactive report: `report.html` (open in a browser).
Regenerate: `./submit_compare.sh && python3 compare_results.py && python3 build_report.py`

---

## The headline, stated honestly

The cutover changed **two** things at once — the protocol (NFS→BeeGFS) *and* the
disks (one 7200rpm HDD → four SSDs). Comparing `/home` to BeeGFS credits BeeGFS
for the SSDs, so it is not the number to quote.

| Comparison | File creation | What it actually measures |
|---|---|---|
| BeeGFS vs NFS **on the same SSDs** | **1.8×** | the protocol alone |
| BeeGFS vs `/home` | **156×** | protocol **+** SSD vs spinning disk |

The 1.8× is the defensible claim for "BeeGFS is faster than NFS".

## Peak file creation (ops/sec)

| Filesystem | Peak | Scaling behaviour |
|---|---|---|
| BeeGFS (4 clients) | **9,028** | rises to ~9k, holds |
| NFS on SSD (pre-cutover) | 4,027 | plateaus at ~4k |
| NFS on HDD (`/home`) | **58** | dead flat from 4 to 48 ranks |
| node-local ext4 (reference) | 497,111 | not a shared FS |

## Protocol comparison — same SSDs, same 3 clients

| Operation | NFS/SSD | BeeGFS | Speedup |
|---|---|---|---|
| File creation (12 ranks) | 4,027 | 8,248 | 2.0× |
| File removal (12 ranks) | 3,904 | 9,837 | 2.5× |
| File stat (12 ranks) | 63,140 | 81,345 | 1.3× |
| Directory removal (12 ranks) | 3,171 | 7,979 | 2.5× |
| Directory stat (12 ranks) | 48,685 | 57,225 | 1.2× |

File *removal* is BeeGFS's biggest win (2.5–4.7×). File *stat* is its smallest
(1.3–1.7×) — reads were never NFS's weak point.

## Conclusions

1. **BeeGFS is genuinely faster, but the SSDs did most of the work.** On identical
   hardware it is 1.8× faster at creating files, not 156×.
2. **BeeGFS scales; NFS plateaus.** NFS saturates its single server at ~4k
   creates/sec. BeeGFS spreads metadata over 2 servers and data over 4.
3. **`/home` is now the cluster's bottleneck.** Still NFS on one 7200rpm HDD at
   58 creates/sec, and completely flat from 4 to 48 ranks — adding clients buys
   nothing at all. Conda envs, pip installs and job scripts all live there.
   Moving that workload to BeeGFS is the next real win.

## Data quality

Two classes of measurement were **excluded rather than reported**:

- **`noisy`** — std dev exceeded half the mean; the phase finished too fast to
  time reliably at 64 files/rank. Mostly affects tree ops and low-rank directory ops.
- **`cached`** — the value exceeded node-local ext4 throughput, which a *shared*
  filesystem cannot beat per node. The client answered from its own dentry cache.
  This hit BeeGFS `Directory stat` at 16+ ranks, which reported 3.2M–6.1M ops/sec.
  The `-N` stride defeats caching for files but BeeGFS clients still cache
  directory entries.

Because every matched Directory-creation point was flagged noisy, **no
Directory-creation speedup claim is made**.

## Method notes

- Zero-byte files: this is a **metadata** benchmark only. It says nothing about
  bandwidth — use `ior` for that.
- mdtest's `File read` row is excluded everywhere: with no payload it only
  measures open/close.
- Stat phase strided by ranks-per-node (`-N`) so a rank stats files created on a
  *different* node.
- One job at a time (`--exclusive` + Slurm singleton dependency).
- Idle verified before and after: no other users' jobs, no interactive users,
  server disks ~0% utilisation.
- An earlier attempt was **discarded** because the login node had ten active
  users with its disk 92–98% busy; those runs are in `results/archive_contaminated/`.
- NFS-on-SSD figures come from `/haydean` shortly *before* the cutover — same
  path, parameters and client set, so they compare directly against BeeGFS
  measured at the same path afterwards.
