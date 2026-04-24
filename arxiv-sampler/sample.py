#!/usr/bin/env python3
"""Random-sample recent arxiv math papers and run tip-mode against each.

Usage:
    ./sample.py [--n 10] [--category math.AP] [--timeout 180]

For each paper:
  1. Fetch tarball from https://arxiv.org/e-print/<id>.
  2. Extract into a tmpdir.
  3. Guess the root .tex file (largest .tex containing \\documentclass).
  4. Run `emacs --batch -l batch.el` with tip-mode active.
  5. Collect (detected, rendered, errored, first-error, elapsed) per paper.

Prints a markdown summary table plus a JSON blob with every row.
Exits 0; per-paper failures are captured as data, not as exit status.

Arxiv etiquette: sleeps 3s between tarball downloads.  Picks random IDs
from the last 2 weeks of listings (export API), so runs are
reproducible-ish but not deterministic.
"""

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from xml.etree import ElementTree as ET

ARXIV_API = "https://export.arxiv.org/api/query"
ARXIV_SRC = "https://arxiv.org/e-print/{}"
ATOM_NS = {"a": "http://www.w3.org/2005/Atom"}
HEADERS = {"User-Agent": "tip-arxiv-sampler/0.1 (https://github.com/local/tip)"}
REPO_ROOT = Path(__file__).resolve().parent.parent

# Catastrophic-failure regression DB.  Every zero-render row gets
# appended to the log + has its tarball stashed so future runs can
# replay the exact-same source and verify a fix resolves it.
HERE = Path(__file__).resolve().parent
CATASTROPHIC_LOG = HERE / "catastrophic.jsonl"
REGRESSIONS_DIR = HERE / "regressions"


def fetch_ids(category: str, want: int) -> list[str]:
    """Random IDs from a recent slice; over-fetch then sample to avoid
    repeatedly pulling the same top-of-list papers across runs."""
    params = (
        f"search_query=cat:{category}&max_results={max(want * 4, 40)}"
        "&sortBy=submittedDate&sortOrder=descending"
    )
    url = f"{ARXIV_API}?{params}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS)) as r:
        body = r.read().decode()
    tree = ET.fromstring(body)
    ids = []
    for entry in tree.findall("a:entry", ATOM_NS):
        idtag = entry.find("a:id", ATOM_NS)
        if idtag is None:
            continue
        # id looks like "http://arxiv.org/abs/2401.12345v1"
        m = re.search(r"abs/([0-9]{4}\.[0-9]{4,5})(v\d+)?$", idtag.text.strip())
        if m:
            ids.append(m.group(1))
    random.shuffle(ids)
    return ids[:want]


def fetch_source(arxiv_id: str, dest: Path) -> bool:
    """Download + extract the e-print tarball into dest.  Returns True on
    success.  Arxiv e-prints are .tar.gz, .gz (single tex), or .pdf-only."""
    url = ARXIV_SRC.format(arxiv_id)
    tgz = dest / "src.tgz"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS)) as r:
            tgz.write_bytes(r.read())
    except Exception as e:
        print(f"  fetch failed: {e}", file=sys.stderr)
        return False
    # e-prints come in several wrappers.  Try tarball; fall back to gunzip
    # for single-file .tex.gz submissions.
    extract_dir = dest / "src"
    extract_dir.mkdir()
    try:
        subprocess.run(
            ["tar", "-xzf", str(tgz), "-C", str(extract_dir)],
            check=True,
            capture_output=True,
        )
        return True
    except subprocess.CalledProcessError:
        pass
    try:
        # Maybe a gzipped single .tex?
        out = extract_dir / f"{arxiv_id}.tex"
        subprocess.run(
            ["sh", "-c", f"gunzip -c {tgz} > {out}"],
            check=True,
            capture_output=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def guess_root(src_dir: Path) -> Path | None:
    """The 'root' is the largest .tex file whose first 4KB contains
    \\documentclass.  Simple, matches how arxiv submissions actually
    look (one main file, rest \\input'd)."""
    candidates = []
    for tex in src_dir.rglob("*.tex"):
        if not tex.is_file():
            continue
        try:
            head = tex.read_bytes()[:4096].decode("utf-8", errors="replace")
        except Exception:
            continue
        if r"\documentclass" in head:
            candidates.append((tex.stat().st_size, tex))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


def run_emacs(root: Path, paper_id: str, timeout: int) -> dict:
    """Spawn `emacs --batch` running batch.el; parse the ARXIV-SAMPLE: line."""
    batch_el = Path(__file__).resolve().parent / "batch.el"
    env = dict(os.environ)
    env.setdefault("TIP_REPO", str(REPO_ROOT))
    cmd = [
        "emacs", "--batch", "-Q",
        "-l", str(batch_el),
        "--eval", f'(tip-sampler-run "{root}" "{paper_id}")',
    ]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, timeout=timeout, env=env, text=True
        )
    except subprocess.TimeoutExpired:
        return {
            "id": paper_id, "root": str(root), "detected": 0, "rendered": 0,
            "errored": 0, "first-error": "TIMEOUT", "elapsed": timeout,
        }
    for line in (proc.stdout + proc.stderr).splitlines():
        if line.startswith("ARXIV-SAMPLE: "):
            return json.loads(line[len("ARXIV-SAMPLE: "):])
    return {
        "id": paper_id, "root": str(root), "detected": 0, "rendered": 0,
        "errored": 0, "first-error": f"NO-REPORT (stderr tail: {proc.stderr[-200:]!r})",
        "elapsed": 0,
    }


def capture_catastrophic(paper_id: str, row: dict, src_dir: Path) -> None:
    """Stash a zero-render paper's tarball + append a JSONL row.
    Skips if the id is already recorded (avoid duplicate tarballs)."""
    REGRESSIONS_DIR.mkdir(exist_ok=True)
    dest = REGRESSIONS_DIR / f"{paper_id}.tar.gz"
    if not dest.exists():
        # Re-pack the extracted src dir — the original tarball is gone
        # by the time we notice the failure.
        subprocess.run(
            ["tar", "-czf", str(dest), "-C", str(src_dir), "."],
            check=True, capture_output=True,
        )
    entry = {
        "id": paper_id,
        "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "detected": row.get("detected", 0),
        "rendered": row.get("rendered", 0),
        "first_error": row.get("first-error"),
        "elapsed": row.get("elapsed"),
    }
    with CATASTROPHIC_LOG.open("a") as f:
        f.write(json.dumps(entry) + "\n")


def load_regressions() -> list[tuple[str, Path]]:
    """Return [(id, tarball_path), ...] for every captured catastrophe."""
    if not REGRESSIONS_DIR.exists():
        return []
    return sorted(
        (p.stem, p) for p in REGRESSIONS_DIR.glob("*.tar.gz")
    )


def extract_regression(tarball: Path, dest: Path) -> bool:
    dest.mkdir()
    try:
        subprocess.run(
            ["tar", "-xzf", str(tarball), "-C", str(dest)],
            check=True, capture_output=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10, help="papers to sample")
    ap.add_argument("--category", default="math.AP", help="arxiv category")
    ap.add_argument("--timeout", type=int, default=180, help="per-paper seconds")
    ap.add_argument("--sleep", type=float, default=3.0, help="between fetches")
    ap.add_argument(
        "--regress", action="store_true",
        help="replay every paper in regressions/ (no fetch)",
    )
    args = ap.parse_args()

    if args.regress:
        captured = load_regressions()
        print(f"Replaying {len(captured)} captured failures…", file=sys.stderr)
        rows = []
        with tempfile.TemporaryDirectory(prefix="tip-regress-") as work_root:
            work_root = Path(work_root)
            for i, (paper_id, tarball) in enumerate(captured):
                print(f"\n[{i+1}/{len(captured)}] {paper_id}", file=sys.stderr)
                paper_dir = work_root / paper_id
                if not extract_regression(tarball, paper_dir):
                    rows.append({
                        "id": paper_id, "root": "", "detected": 0, "rendered": 0,
                        "warned": 0, "errored": 0,
                        "first-error": "EXTRACT", "elapsed": 0,
                    })
                    continue
                root = guess_root(paper_dir)
                if root is None:
                    rows.append({
                        "id": paper_id, "root": "", "detected": 0, "rendered": 0,
                        "warned": 0, "errored": 0,
                        "first-error": "NO-ROOT", "elapsed": 0,
                    })
                    continue
                row = run_emacs(root, paper_id, args.timeout)
                print(
                    f"  → detected={row['detected']} rendered={row['rendered']} "
                    f"warned={row.get('warned', 0)} errored={row['errored']} "
                    f"elapsed={row['elapsed']:.1f}s",
                    file=sys.stderr,
                )
                rows.append(row)
        print_report(rows)
        return

    print(f"Fetching {args.n} random ids from {args.category}…", file=sys.stderr)
    ids = fetch_ids(args.category, args.n)
    print(f"  got {len(ids)}: {ids}", file=sys.stderr)

    rows = []
    with tempfile.TemporaryDirectory(prefix="tip-arxiv-") as work_root:
        work_root = Path(work_root)
        for i, arxiv_id in enumerate(ids):
            print(f"\n[{i+1}/{len(ids)}] {arxiv_id}", file=sys.stderr)
            paper_dir = work_root / arxiv_id
            paper_dir.mkdir()
            if not fetch_source(arxiv_id, paper_dir):
                rows.append({
                    "id": arxiv_id, "root": "", "detected": 0, "rendered": 0,
                    "errored": 0, "first-error": "FETCH", "elapsed": 0,
                })
                time.sleep(args.sleep)
                continue
            root = guess_root(paper_dir / "src")
            if root is None:
                rows.append({
                    "id": arxiv_id, "root": "", "detected": 0, "rendered": 0,
                    "errored": 0, "first-error": "NO-ROOT", "elapsed": 0,
                })
                time.sleep(args.sleep)
                continue
            print(f"  root: {root.relative_to(paper_dir)}", file=sys.stderr)
            row = run_emacs(root, arxiv_id, args.timeout)
            print(
                f"  → detected={row['detected']} rendered={row['rendered']} "
                f"warned={row.get('warned', 0)} errored={row['errored']} "
                f"elapsed={row['elapsed']:.1f}s",
                file=sys.stderr,
            )
            rows.append(row)
            # Stash catastrophic failures (0 rendered) as regressions.
            if row.get("detected", 0) > 0 and row.get("rendered", 0) == 0:
                try:
                    capture_catastrophic(arxiv_id, row, paper_dir / "src")
                    print(f"  CAPTURED as regression → {REGRESSIONS_DIR / f'{arxiv_id}.tar.gz'}",
                          file=sys.stderr)
                except Exception as e:
                    print(f"  capture failed: {e}", file=sys.stderr)
            time.sleep(args.sleep)

    print_report(rows)


def print_report(rows: list[dict]) -> None:
    print("\n## Summary\n")
    print("| id | detected | rendered | warned | errored | elapsed | first error |")
    print("|----|----------|----------|--------|---------|---------|-------------|")
    for r in rows:
        err = r.get("first-error") or ""
        if err is None or err == "null":
            err = ""
        err = str(err).replace("|", "\\|")[:60]
        print(
            f"| {r['id']} | {r['detected']} | {r['rendered']} | "
            f"{r.get('warned', 0)} | {r['errored']} | {r['elapsed']:.1f}s | {err} |"
        )
    total = len(rows)
    fully = sum(1 for r in rows if r["detected"] > 0 and r["rendered"] == r["detected"])
    none = sum(1 for r in rows if r["rendered"] == 0)
    print(f"\n**{fully}/{total} fully rendered**, {none} zero-render")
    if CATASTROPHIC_LOG.exists():
        with CATASTROPHIC_LOG.open() as f:
            captured = sum(1 for _ in f)
        print(f"Regression DB: {captured} catastrophic failures logged "
              f"({REGRESSIONS_DIR.relative_to(REPO_ROOT)}/)")
    print("\n<details><summary>raw rows (JSON)</summary>\n\n```json")
    print(json.dumps(rows, indent=2))
    print("```\n</details>")


if __name__ == "__main__":
    main()
