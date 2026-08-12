#!/usr/bin/env python3
"""Compare BeeGFS vs NFS mdtest results.

Emits a readable table to stdout and a JSON blob (results/comparison.json)
used to build the HTML report.
"""
import json
import re
import sys
from pathlib import Path

BASE = Path("/home/hpcadmin/storagebenchmarks")
RESULTS = BASE / "results"

# tag -> (human label, filesystem kind, media, client count)
SERIES = {
    "hay3n":    ("NFS on SSD",      "NFS",     "SSD", 3),
    "beegfs3n": ("BeeGFS on SSD",   "BeeGFS",  "SSD", 3),
    "beegfs4n": ("BeeGFS on SSD",   "BeeGFS",  "SSD", 4),
    "nfshdd4n": ("NFS on HDD",      "NFS",     "HDD", 4),
    "local1n":  ("node-local ext4", "local",   "SSD", 1),
}

# "File read" is excluded everywhere: with no -w/-e the files are zero-byte, so
# mdtest's read phase is just open/close and the numbers are meaningless.
OPS = ["File creation", "File stat", "File removal",
       "Directory creation", "Directory stat", "Directory removal",
       "Tree creation", "Tree removal"]

ROW = re.compile(r"^\s{2,}([A-Za-z][A-Za-z ]+?)\s+"
                 r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$")


def parse(path):
    text = path.read_text(errors="replace")
    if "mdtest exit=0" not in text:
        return None
    m = re.search(r"^ntasks\s*:\s*(\d+)\s*\((\d+) nodes x (\d+) ranks\)", text, re.M)
    tag = re.search(r"^### mdtest (\S+)", text, re.M)
    if not m or not tag or tag[1] not in SERIES:
        return None
    rec = {"tag": tag[1], "ranks": int(m[1]), "nodes": int(m[2]), "rpn": int(m[3]), "ops": {}}
    for line in text.split("SUMMARY rate")[-1].splitlines():
        r = ROW.match(line)
        if r:
            mean, sd = float(r[4]), float(r[5])
            # A phase that finishes too fast to time reliably reports a std dev
            # comparable to (or larger than) its own mean. Those points are
            # timer noise, not throughput -- flag them so they can be excluded
            # rather than published as multi-million-ops/sec results.
            rec["ops"][r[1].strip()] = {
                "mean": round(mean, 1),
                "sd": round(sd, 1),
                "unreliable": bool(mean > 0 and sd / mean > 0.5),
            }
    return rec if rec["ops"] else None


def val(rec, op, allow_unreliable=False):
    """Mean for an op, or None if missing / flagged unreliable."""
    o = rec["ops"].get(op)
    if not o or (o["unreliable"] and not allow_unreliable):
        return None
    return o["mean"]


def flag_cached(recs):
    """Mark network-FS values that exceed node-local ext4 as client-cached.

    A shared filesystem cannot serve metadata faster, per node, than a local
    ext4 on the same hardware. When it appears to, the client answered from its
    own dentry cache and the number describes RAM, not the storage servers.
    The -N stride defeats caching for *files* but BeeGFS clients still cache
    directory entries, which is where this shows up.
    """
    local = {}
    for r in recs:
        if r["tag"] == "local1n":
            local = {k: v["mean"] for k, v in r["ops"].items()}
    if not local:
        return
    for r in recs:
        if r["tag"] == "local1n":
            continue
        for op, o in r["ops"].items():
            ceiling = local.get(op)
            if ceiling and o["mean"] > ceiling:
                o["unreliable"] = True
                o["cached"] = True


def main():
    recs = [r for r in (parse(p) for p in sorted(RESULTS.glob("*.txt"))) if r]
    if not recs:
        print("no results yet")
        return 1
    flag_cached(recs)

    by_tag = {}
    for r in recs:
        by_tag.setdefault(r["tag"], []).append(r)
    for v in by_tag.values():
        v.sort(key=lambda r: r["ranks"])

    # ── headline: the protocol comparison at matched client count ────────────
    print("=" * 78)
    print("PROTOCOL COMPARISON — same 3 clients, same SSDs, same mdtest settings")
    print("  NFS on SSD  = /haydean before the BeeGFS cutover")
    print("  BeeGFS      = /haydean after the cutover")
    print("=" * 78)
    nfs = {r["ranks"]: r for r in by_tag.get("hay3n", [])}
    bee = {r["ranks"]: r for r in by_tag.get("beegfs3n", [])}
    shared = sorted(set(nfs) & set(bee))
    if shared:
        print(f"{'operation':<20}{'ranks':>6}{'NFS/SSD':>13}{'BeeGFS':>13}{'speedup':>10}")
        print("-" * 78)
        for op in OPS:
            for n in shared:
                a, b = val(nfs[n], op), val(bee[n], op)
                if a and b:
                    print(f"{op:<20}{n:>6}{a:>13,.0f}{b:>13,.0f}{b/a:>9.1f}x")
            print()

    # ── every series, full scaling curves ────────────────────────────────────
    for tag, rs in by_tag.items():
        label, kind, media, _ = SERIES[tag]
        print("=" * 78)
        print(f"{label}  ({kind} on {media}) — {rs[0]['nodes']} client node(s)")
        print("=" * 78)
        hdr = f"{'operation':<20}" + "".join(f"{r['ranks']:>12}" for r in rs)
        print(hdr + "   <- ranks")
        print("-" * len(hdr))
        for op in OPS:
            if any(op in r["ops"] for r in rs):
                cells = []
                for r in rs:
                    v = val(r, op)
                    cells.append(f"{v:>12,.0f}" if v is not None else f"{'noisy':>12}")
                print(f"{op:<20}" + "".join(cells))
        print()
    print("'noisy' = std dev exceeded half the mean; the phase completed too")
    print("fast to time reliably. Excluded rather than reported.\n")

    out = {"series": {t: {"label": SERIES[t][0], "kind": SERIES[t][1],
                          "media": SERIES[t][2], "runs": rs}
                      for t, rs in by_tag.items()},
           "ops": OPS}
    (RESULTS / "comparison.json").write_text(json.dumps(out, indent=2))
    print(f"wrote {RESULTS / 'comparison.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
