#!/usr/bin/env python3
"""End-to-end check: build a demo disk, scan it, and assert on the JSON report.

    python scripts/e2e.py path/to/chunkmap[.exe]
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main() -> None:
    exe = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory() as tmp:
        data = os.path.join(tmp, "disk")
        subprocess.run([sys.executable, os.path.join(HERE, "make_demo_data.py"), data], check=True)
        report = os.path.join(tmp, "report.json")
        html = os.path.join(tmp, "report.html")
        subprocess.run([exe, "scan", data, "-q", "--color", "never", "--json", report, "--html", html], check=True, stdout=subprocess.DEVNULL)
        r = json.load(open(report, encoding="utf-8"))
        s = r["summary"]

        def check(cond, msg):
            if not cond:
                sys.exit(f"FAIL: {msg}")
            print(f"ok   {msg}")

        check(r["tool"] == "chunkmap" and r["schema"] == 1, "report header")
        check(s["files"] == 85, f"85 files scanned (got {s['files']})")
        check(s["bytes"] == s["unique_bytes"] + s["reclaimable_bytes"], "bytes = unique + reclaimable")
        check(0.40 < s["reclaimable_bytes"] / s["bytes"] < 0.50, "reclaimable share is ~45%")
        iso = [g for g in r["duplicate_groups"] if g["paths"][0].endswith(".iso")]
        check(len(iso) == 1 and len(iso[0]["paths"]) == 2, "duplicate ISO download detected")
        pairs = {(os.path.basename(p["a"]), os.path.basename(p["b"])) for p in r["similar_pairs"]}
        check(("holiday-trimmed.mp4", "holiday-raw.mp4") in pairs, "trimmed video matched with original")
        check(("app.log", "app.log.1") in pairs, "rotated log matched")
        check(any("thesis-v1" in a + b for a, b in pairs), "thesis versions matched")
        check(s["internal_redundant_bytes"] > 0, "in-file repetition (VM image) detected")
        page = open(html, encoding="utf-8").read()
        check('id="chunkmap-data"' in page and "__CHUNKMAP_DATA__" not in page, "HTML report embeds data")

        out = subprocess.run([exe, "compare", os.path.join(data, "Downloads", "invoice-2024-09.pdf"),
                              os.path.join(data, "Downloads", "invoice-2024-09 (1).pdf"), "--color", "never"],
                             check=True, capture_output=True).stdout.decode("utf-8")
        check("identical" in out, "compare recognises identical files")
        bad = subprocess.run([exe, "scan", os.path.join(tmp, "missing")], capture_output=True)
        check(bad.returncode == 2, "missing path exits with code 2")
    print("all end-to-end checks passed")


if __name__ == "__main__":
    main()
