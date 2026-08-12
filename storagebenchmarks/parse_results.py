#!/usr/bin/env python3
"""Parse mdtest result files into a comparison table (ops/sec)."""
import re
import sys
from pathlib import Path

RESULTS = Path("/home/hpcadmin/storagebenchmarks/results")

# "   File creation                  48.625    48.625    48.625     0.000"
ROW = re.compile(r"^\s{2,}([A-Za-z][A-Za-z ]+?)\s+"
                 r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$")

OPS = ["Directory creation", "Directory stat", "Directory removal",
       "File creation", "File stat", "File read", "File removal",
       "Tree creation", "Tree removal"]


def parse(path):
    text = path.read_text(errors="replace")
    if "mdtest exit=0" not in text:
        return None
    rec = {"file": path.name, "ops": {}}
    m = re.search(r"^ntasks\s*:\s*(\d+)\s*\((\d+) nodes x (\d+) ranks\)",
                  text, re.M)
    if not m:
        return None
    rec["ntasks"], rec["nodes"], rec["rpn"] = (int(m[1]), int(m[2]), int(m[3]))
    rec["tag"] = re.search(r"^### mdtest (\S+)", text, re.M)[1]
    rec["target"] = re.search(r"^target\s*:\s*(\S+)", text, re.M)[1]

    # only read the SUMMARY block, so per-iteration noise is not picked up
    summary = text.split("SUMMARY rate")[-1]
    for line in summary.splitlines():
        m = ROW.match(line)
        if m:
            rec["ops"][m[1].strip()] = (float(m[4]), float(m[5]))  # mean, stddev
    return rec if rec["ops"] else None


def main():
    recs = sorted((r for r in (parse(p) for p in sorted(RESULTS.glob("*.txt"))) if r),
                  key=lambda r: (r["tag"], r["ntasks"]))
    if not recs:
        print("no completed results found")
        return 1

    groups = {}
    for r in recs:
        groups.setdefault(r["tag"], []).append(r)

    for tag, rs in groups.items():
        print(f"\n{'=' * 100}")
        print(f"{tag}    target: {rs[0]['target']}")
        print("=" * 100)
        hdr = f"{'operation':<20}" + "".join(f"{r['ntasks']:>12}" for r in rs)
        print(hdr)
        print(f"{'(ranks ->)':<20}" + "".join(
            f"{str(r['nodes']) + 'n x' + str(r['rpn']):>12}" for r in rs))
        print("-" * len(hdr))
        for op in OPS:
            if not any(op in r["ops"] for r in rs):
                continue
            row = f"{op:<20}"
            for r in rs:
                v = r["ops"].get(op)
                row += f"{v[0]:>12,.1f}" if v else f"{'-':>12}"
            print(row)
    print("\nAll values are mean ops/sec over the run's iterations.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
