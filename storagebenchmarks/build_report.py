#!/usr/bin/env python3
"""Build a self-contained HTML report from results/comparison.json."""
import json
import math
from pathlib import Path

BASE = Path("/home/hpcadmin/storagebenchmarks")
DATA = json.loads((BASE / "results" / "comparison.json").read_text())
OUT = BASE / "report.html"

# Categorical slots 1-3 from the validated palette (all-pairs safe, both modes).
SERIES_STYLE = {
    "beegfs": ("BeeGFS (SSD)", "#2a78d6"),
    "nfsssd": ("NFS (SSD)",    "#eb6834"),
    "nfshdd": ("NFS (HDD)",    "#1baf7a"),
}
TAG_TO_KEY = {"beegfs3n": "beegfs", "beegfs4n": "beegfs",
              "hay3n": "nfsssd", "nfshdd4n": "nfshdd"}

CHART_OPS = ["File creation", "File stat", "File removal",
             "Directory creation", "Directory stat", "Directory removal"]


def runs(tag):
    s = DATA["series"].get(tag)
    return s["runs"] if s else []


def val(rec, op):
    o = rec["ops"].get(op)
    return None if not o or o.get("unreliable") else o["mean"]


def cell(rec, op):
    o = rec["ops"].get(op)
    if not o:
        return "—", ""
    if o.get("cached"):
        return "cached", "flag"
    if o.get("unreliable"):
        return "noisy", "flag"
    return f'{o["mean"]:,.0f}', ""


# ── speedup: BeeGFS vs NFS-SSD, matched 3-client runs ───────────────────────
def speedup_rows():
    nfs = {r["ranks"]: r for r in runs("hay3n")}
    bee = {r["ranks"]: r for r in runs("beegfs3n")}
    out = []
    for op in CHART_OPS:
        vals = []
        for n in sorted(set(nfs) & set(bee)):
            a, b = val(nfs[n], op), val(bee[n], op)
            if a and b:
                vals.append(b / a)
        if vals:
            out.append((op, sum(vals) / len(vals), min(vals), max(vals), len(vals)))
    return out


def speedup_chart():
    rows = speedup_rows()
    if not rows:
        return ""
    W, rowh, lab = 680, 44, 168
    H = len(rows) * rowh + 46
    hi = max(3.0, max(r[3] for r in rows) * 1.10)
    plot = W - lab - 70

    def x(v):
        return lab + (v / hi) * plot

    p = [f'<svg viewBox="0 0 {W} {H}" class="chart" role="img" '
         f'aria-label="Speedup of BeeGFS over NFS on the same SSDs, by operation">']
    p.append(f'<line x1="{x(1):.1f}" y1="26" x2="{x(1):.1f}" y2="{H - 18}" class="parity"/>')
    p.append(f'<text x="{x(1):.1f}" y="18" class="axlab mid">1× — no difference</text>')
    for i, (op, mean, lo, hiv, n) in enumerate(rows):
        y = 32 + i * rowh
        p.append(f'<text x="{lab - 10}" y="{y + 15}" class="rowlab end">{op}</text>')
        p.append(f'<rect x="{lab}" y="{y}" width="{max(1, x(mean) - lab):.1f}" '
                 f'height="21" rx="4" class="bar"/>')
        if hiv - lo > 0.05:
            p.append(f'<line x1="{x(lo):.1f}" y1="{y + 10.5}" x2="{x(hiv):.1f}" '
                     f'y2="{y + 10.5}" class="whisk"/>')
        p.append(f'<text x="{x(mean) + 8:.1f}" y="{y + 16}" class="val">{mean:.1f}×</text>')
    p.append('</svg>')
    return "".join(p)


# ── log-scale scaling curves, small multiples ───────────────────────────────
def scaling_chart(op):
    series = []
    for tag, key in (("beegfs4n", "beegfs"), ("hay3n", "nfsssd"), ("nfshdd4n", "nfshdd")):
        pts = [(r["ranks"], val(r, op)) for r in runs(tag)]
        pts = [(a, b) for a, b in pts if b]
        if pts:
            series.append((key, sorted(pts)))
    if not series:
        return ""

    W, H, L, R, T, B = 340, 205, 50, 12, 16, 34
    allv = [v for _, ps in series for _, v in ps]
    allr = [r for _, ps in series for r, _ in ps]
    lo, hi = math.floor(math.log10(max(1, min(allv)))), math.ceil(math.log10(max(allv)))
    rmin, rmax = min(allr), max(allr)

    def X(r):
        span = max(1e-9, math.log2(rmax) - math.log2(rmin))
        return L + (math.log2(r) - math.log2(rmin)) / span * (W - L - R)

    def Y(v):
        return H - B - (math.log10(max(1, v)) - lo) / max(1e-9, hi - lo) * (H - T - B)

    p = [f'<svg viewBox="0 0 {W} {H}" class="chart sm" role="img" '
         f'aria-label="{op}: operations per second versus MPI ranks, log scale">']
    for e in range(int(lo), int(hi) + 1):
        y = Y(10 ** e)
        p.append(f'<line x1="{L}" y1="{y:.1f}" x2="{W - R}" y2="{y:.1f}" class="grid"/>')
        v = 10 ** e
        lbl = f'{v // 1000}k' if v >= 1000 else str(v)
        p.append(f'<text x="{L - 6}" y="{y + 3.5:.1f}" class="tick end">{lbl}</text>')
    for r in sorted(set(allr)):
        p.append(f'<text x="{X(r):.1f}" y="{H - 14}" class="tick mid">{r}</text>')
    p.append(f'<text x="{(L + W - R) / 2:.0f}" y="{H - 2}" class="axtitle mid">MPI ranks</text>')
    for key, ps in series:
        d = " ".join(f'{"M" if i == 0 else "L"}{X(r):.1f},{Y(v):.1f}'
                     for i, (r, v) in enumerate(ps))
        p.append(f'<path d="{d}" class="ln {key}"/>')
        for r, v in ps:
            p.append(f'<circle cx="{X(r):.1f}" cy="{Y(v):.1f}" r="4.5" class="pt {key}"/>')
    p.append('</svg>')
    return f'<figure class="sm-fig"><figcaption>{op}</figcaption>{"".join(p)}</figure>'


def table():
    h = ['<table><thead><tr><th>Filesystem</th><th class="n">Clients</th>'
         '<th class="n">Ranks</th>']
    h += [f'<th class="n">{o}</th>' for o in CHART_OPS]
    h.append('</tr></thead><tbody>')
    for tag in ["beegfs4n", "beegfs3n", "hay3n", "nfshdd4n"]:
        s = DATA["series"].get(tag)
        if not s:
            continue
        key = TAG_TO_KEY[tag]
        label = SERIES_STYLE[key][0]
        for r in s["runs"]:
            h.append(f'<tr><td><span class="dot {key}"></span>{label}</td>'
                     f'<td class="n">{r["nodes"]}</td><td class="n">{r["ranks"]}</td>')
            for o in CHART_OPS:
                txt, cls = cell(r, o)
                h.append(f'<td class="n {cls}">{txt}</td>')
            h.append('</tr>')
    h.append('</tbody></table>')
    return "".join(h)


def legend():
    return '<div class="legend">' + "".join(
        f'<span class="lg"><span class="dot {k}"></span>{v[0]}</span>'
        for k, v in SERIES_STYLE.items()) + '</div>'


rows = speedup_rows()
fc = next((r for r in rows if r[0] == "File creation"), ("", 0, 0, 0, 0))
peak = lambda tag: max((val(r, "File creation") or 0) for r in runs(tag)) if runs(tag) else 0
bee_peak, hdd_peak, ssd_peak = peak("beegfs4n"), peak("nfshdd4n"), peak("hay3n")
combined = bee_peak / hdd_peak if hdd_peak else 0

CSS = """
*{box-sizing:border-box}
/* Tokens live on :root so body -- which sits ABOVE .viz-root -- can resolve
   them. Defining them on .viz-root left body's background unresolved, since
   custom properties inherit downward only. */
:root{color-scheme:light;
 --surface-1:#fcfcfb;--plane:#f9f9f7;--text-primary:#0b0b0b;--text-secondary:#52514e;
 --muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--border:rgba(11,11,11,0.10);
 --beegfs:#2a78d6;--nfsssd:#eb6834;--nfshdd:#1baf7a;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
 color-scheme:dark;--surface-1:#1a1a19;--plane:#0d0d0d;--text-primary:#fff;
 --text-secondary:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;
 --border:rgba(255,255,255,0.10);--beegfs:#3987e5;--nfsssd:#d95926;--nfshdd:#199e70;}}
:root[data-theme="dark"]{color-scheme:dark;
 --surface-1:#1a1a19;--plane:#0d0d0d;--text-primary:#fff;--text-secondary:#c3c2b7;
 --muted:#898781;--grid:#2c2c2a;--axis:#383835;--border:rgba(255,255,255,0.10);
 --beegfs:#3987e5;--nfsssd:#d95926;--nfshdd:#199e70;}
body{margin:0;background:var(--plane);color:var(--text-primary);
 font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
.viz-root{max-width:940px;margin:0 auto;padding:34px 20px 72px;background:var(--plane)}
.eyebrow{font-size:11.5px;font-weight:640;letter-spacing:.10em;text-transform:uppercase;
 color:var(--muted);margin:0 0 10px}
h1{font-size:29px;line-height:1.2;margin:0 0 8px;letter-spacing:-.018em;
 text-wrap:balance;font-weight:660}
.sub{color:var(--text-secondary);margin:0 0 22px;font-size:14.5px}
h2{font-size:18px;margin:38px 0 4px;letter-spacing:-.008em;font-weight:640;
 text-wrap:balance}
.note{color:var(--text-secondary);font-size:14px;margin:0 0 14px}
.card{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;
 padding:18px 20px;margin:14px 0}
.hero{display:flex;flex-wrap:wrap;gap:14px;margin:18px 0 6px}
.stat{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;
 padding:14px 18px;flex:1 1 210px}
.stat .v{font-size:30px;font-weight:640;letter-spacing:-.02em;line-height:1.1}
.stat .k{color:var(--text-secondary);font-size:13px;margin-top:4px}
.chart{width:100%;height:auto;display:block;overflow:visible}
.sm{max-width:340px}
.grid-sm{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:12px}
.sm-fig{margin:0;background:var(--surface-1);border:1px solid var(--border);
 border-radius:10px;padding:10px 8px 4px}
.sm-fig figcaption{font-size:13.5px;font-weight:600;margin:2px 0 2px 10px}
.bar{fill:var(--beegfs)}
.parity{stroke:var(--axis);stroke-width:2;stroke-dasharray:4 4}
.whisk{stroke:var(--surface-1);stroke-width:2;opacity:.9}
.rowlab{fill:var(--text-primary);font-size:13.5px}
.val{fill:var(--text-primary);font-size:13.5px;font-weight:640}
.axlab{fill:var(--muted);font-size:12px}
.tick{fill:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}
.axtitle{fill:var(--text-secondary);font-size:11.5px}
.grid{stroke:var(--grid);stroke-width:1}
.end{text-anchor:end}.mid{text-anchor:middle}
.ln{fill:none;stroke-width:2;stroke-linejoin:round}
.ln.beegfs{stroke:var(--beegfs)}.ln.nfsssd{stroke:var(--nfsssd)}.ln.nfshdd{stroke:var(--nfshdd)}
.pt{stroke:var(--surface-1);stroke-width:2}
.pt.beegfs{fill:var(--beegfs)}.pt.nfsssd{fill:var(--nfsssd)}.pt.nfshdd{fill:var(--nfshdd)}
.dot{width:10px;height:10px;border-radius:3px;display:inline-block;margin-right:7px;
 vertical-align:-1px}
.dot.beegfs{background:var(--beegfs)}.dot.nfsssd{background:var(--nfsssd)}
.dot.nfshdd{background:var(--nfshdd)}
.legend{display:flex;gap:20px;flex-wrap:wrap;margin:10px 0 6px;font-size:13.5px;
 color:var(--text-secondary)}
.lg{display:inline-flex;align-items:center}
.tablewrap{overflow-x:auto;background:var(--surface-1);border:1px solid var(--border);
 border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{padding:7px 11px;text-align:left;border-bottom:1px solid var(--border);
 white-space:nowrap}
th{font-weight:600;color:var(--text-secondary);font-size:12px}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
td.flag{color:var(--muted);font-style:italic}
tbody tr:last-child td{border-bottom:none}
ul{margin:8px 0 0;padding-left:20px}li{margin:6px 0}
.warn{border-left:3px solid var(--nfsssd);padding-left:14px}
code{background:var(--grid);padding:1px 5px;border-radius:4px;font-size:12.5px}
"""

HTML = f"""<title>BeeGFS vs NFS — mdtest metadata benchmark</title>
<style>{CSS}</style>
<div class="viz-root">
<p class="eyebrow">haydean cluster · storage evaluation</p>
<h1>BeeGFS vs NFS — metadata benchmark</h1>
<p class="sub">mdtest 4.1.0 · 19 runs · measured on an idle cluster after the BeeGFS cutover</p>

<div class="hero">
  <div class="stat"><div class="v">{fc[1]:.1f}×</div>
    <div class="k">BeeGFS vs NFS at creating files —<br><strong>same SSDs, same clients</strong>.
    This is the protocol's real contribution.</div></div>
  <div class="stat"><div class="v">{combined:,.0f}×</div>
    <div class="k">BeeGFS vs your <code>/home</code> —<br>but most of this gap is
    SSD vs spinning disk, <em>not</em> BeeGFS.</div></div>
  <div class="stat"><div class="v">{hdd_peak:,.0f}</div>
    <div class="k">file creates/sec on <code>/home</code> —<br>flat from 4 to 48 ranks.
    One spindle is the ceiling.</div></div>
</div>

<h2>Reading this honestly</h2>
<p class="note">The cutover changed two things at once: the <strong>protocol</strong>
(NFS→BeeGFS) and the <strong>disks</strong> (one 7200rpm HDD → four SSDs). Comparing
<code>/home</code> against BeeGFS would credit BeeGFS for the SSDs. So the headline
compares BeeGFS against NFS <strong>on the very same SSDs, same three client nodes,
identical mdtest settings</strong> — measured at <code>/haydean</code> just before and
just after the cutover. That isolates the protocol.</p>

<div class="card">
{speedup_chart()}
<p class="note" style="margin:8px 0 0">Bar = mean speedup across the rank sweep; the
pale line spans min–max. Right of the dashed line, BeeGFS wins. Directory creation is
absent because every matched point failed the reliability check below.</p>
</div>

<h2>How each filesystem scales</h2>
<p class="note">Operations/sec against MPI ranks. <strong>The vertical axis is
logarithmic</strong> — NFS-on-HDD is ~150× slower, and a linear axis would flatten it
onto the floor. Missing points were excluded as unreliable.</p>
{legend()}
<div class="grid-sm">
{"".join(scaling_chart(op) for op in CHART_OPS)}
</div>

<h2>What this means</h2>
<div class="card">
<ul>
<li><strong>BeeGFS is genuinely faster, but the SSDs did most of the work.</strong>
On identical hardware BeeGFS creates files <strong>{fc[1]:.1f}×</strong> faster and
removes them ~3× faster. The <strong>{combined:,.0f}×</strong> gap against
<code>/home</code> is mostly the disks.</li>
<li><strong>BeeGFS keeps scaling; NFS plateaus.</strong> NFS-on-SSD file creation
flattens at ~4,000/sec once the single server saturates. BeeGFS reaches
~{bee_peak:,.0f}/sec by spreading metadata across two servers and data across four.</li>
<li><strong>Stat-heavy work is where BeeGFS wins least.</strong> File stat is only
1.3–1.7× better — reads were never NFS's weak point.</li>
<li class="warn"><strong><code>/home</code> is now the bottleneck.</strong> Still NFS
on one 7200rpm HDD at <strong>{hdd_peak:,.0f} creates/sec</strong>, and completely flat
from 4 to 48 ranks — adding clients buys nothing. Conda environments, pip installs and
job scripts all live there. Moving that workload onto BeeGFS is the next real win.</li>
</ul>
</div>

<h2>All measurements</h2>
<p class="note">Mean operations/sec over 2 iterations, 64 files per rank.
<em>noisy</em> = std dev exceeded half the mean (phase too fast to time reliably).
<em>cached</em> = exceeded node-local ext4 speed, so the client answered from its own
cache rather than the servers. Both are excluded from the charts above rather than
reported as results.</p>
<div class="tablewrap">{table()}</div>

<h2>Method</h2>
<div class="card">
<ul>
<li><code>mdtest</code> 4.1.0, 64 files/rank, 2 iterations, stat phase strided by
ranks-per-node so a rank stats files created on a <em>different</em> node.</li>
<li>Zero-byte files: this is a pure <strong>metadata</strong> benchmark. It says
nothing about bandwidth — use <code>ior</code> for that. mdtest's "File read" row is
excluded entirely, since with no payload it only measures open/close.</li>
<li>One job at a time (<code>--exclusive</code> + Slurm singleton dependency);
concurrent jobs would contend for the same servers.</li>
<li>Idle verified before and after: no other users' jobs, no interactive users, server
disks at ~0% utilisation. An <em>earlier</em> attempt was discarded because the login
node had ten active users with its disk 92–98% busy.</li>
<li>NFS-on-SSD figures come from <code>/haydean</code> shortly before the BeeGFS
cutover — same path, same parameters, same client set, so they compare directly.</li>
<li>Reproduce with <code>./submit_compare.sh &amp;&amp; python3 compare_results.py</code>
in <code>~/storagebenchmarks</code>.</li>
</ul>
</div>
</div>
"""

OUT.write_text(HTML)
print(f"wrote {OUT} ({len(HTML):,} bytes)")
print(f"headline: file-create {fc[1]:.1f}x (n={fc[4]} matched points), "
      f"beegfs peak {bee_peak:,.0f}, nfs-ssd peak {ssd_peak:,.0f}, hdd peak {hdd_peak:,.0f}")
