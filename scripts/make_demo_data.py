#!/usr/bin/env python3
"""Generate a deterministic, realistic-looking messy disk for demos and tests.

    python scripts/make_demo_data.py [OUT_DIR] [--scale N]

It reproduces the situations chunkmap is built for:
  * photos copied to a "backup" folder and again into an export folder
  * a downloaded ISO saved twice ("file (1).iso")
  * a thesis saved as v1..v5 where each version inserts/edits text
  * rotated logs where app.log.1 is a prefix of app.log
  * a VM disk image full of repeated blocks
  * two projects with the same vendored dependencies
Everything is pseudo-random from a fixed seed, so reports are reproducible.
"""
import os
import random
import shutil
import sys

SEED = 20241012


def rnd_bytes(rng: random.Random, n: int) -> bytes:
    return rng.randbytes(n)


def write(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def words(rng: random.Random, n: int) -> bytes:
    vocab = ("the data chunk hash file disk backup copy version edit draft final "
             "results method figure table appendix abstract introduction storage "
             "dedup rolling window boundary content defined average").split()
    return " ".join(rng.choice(vocab) for _ in range(n)).encode()


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = args[0] if args else "demo-data"
    scale = 1
    if "--scale" in sys.argv:
        scale = int(sys.argv[sys.argv.index("--scale") + 1])
    rng = random.Random(SEED)
    if os.path.exists(out):
        shutil.rmtree(out)

    MB = 1024 * 1024

    # Photos: originals, a phone backup with most of them, and an export copy of favourites.
    photos = {}
    for i in range(24 * scale):
        name = f"IMG_{2040 + i:04d}.JPG"
        photos[name] = rnd_bytes(rng, rng.randint(2, 6) * MB // 2)
        write(f"{out}/Pictures/2024/Summer/{name}", photos[name])
    for name in list(photos)[: 18 * scale]:
        write(f"{out}/Backup/Phone/DCIM/{name}", photos[name])
    for name in list(photos)[::5]:
        write(f"{out}/Desktop/to-print/{name.replace('IMG', 'print')}", photos[name])

    # Videos: one big clip and a trimmed re-export that keeps most of the bytes.
    clip = rnd_bytes(rng, 28 * MB)
    write(f"{out}/Videos/holiday-raw.mp4", clip)
    write(f"{out}/Videos/exports/holiday-trimmed.mp4", clip[3 * MB : 25 * MB] + rnd_bytes(rng, 256 * 1024))

    # Downloads saved twice.
    iso = rnd_bytes(rng, 24 * MB)
    write(f"{out}/Downloads/ubuntu-24.04-desktop-amd64.iso", iso)
    write(f"{out}/Downloads/ubuntu-24.04-desktop-amd64 (1).iso", iso)
    write(f"{out}/Downloads/invoice-2024-09.pdf", rnd_bytes(rng, 300 * 1024))
    write(f"{out}/Downloads/invoice-2024-09 (1).pdf", open(f"{out}/Downloads/invoice-2024-09.pdf", "rb").read())

    # Thesis versions: every save inserts and edits a few paragraphs.
    doc = bytearray(words(rng, 400_000))
    for v in range(1, 6):
        write(f"{out}/Documents/thesis/thesis-v{v}.docx", bytes(doc))
        for _ in range(3):
            pos = rng.randrange(len(doc))
            doc[pos:pos] = words(rng, rng.randint(50, 400))
        pos = rng.randrange(len(doc) - 5000)
        doc[pos : pos + 2000] = words(rng, 300)
    write(f"{out}/Documents/thesis/thesis-FINAL.docx", bytes(doc))
    write(f"{out}/Documents/thesis/thesis-FINAL-really.docx", bytes(doc))

    # Rotated logs: app.log.1 is the first part of app.log.
    log = b"".join(
        b"2024-10-%02d 12:%02d:%02d INFO request id=%08x path=/api/v1/items status=200 took=%dms\n"
        % (1 + i % 28, i % 60, (i * 7) % 60, rng.getrandbits(32), rng.randint(1, 900))
        for i in range(120_000)
    )
    write(f"{out}/Projects/api-server/logs/app.log.1", log[: len(log) * 2 // 3])
    write(f"{out}/Projects/api-server/logs/app.log", log)

    # Vendored dependencies duplicated across two projects.
    deps = {f"lib/{n}.min.js": words(rng, rng.randint(20_000, 90_000)) for n in ("chart", "lodash", "react-dom", "moment", "three")}
    for proj in ("api-server", "dashboard"):
        for rel, data in deps.items():
            write(f"{out}/Projects/{proj}/vendor/{rel}", data)
        write(f"{out}/Projects/{proj}/src/main.js", words(rng, 5_000))

    # VM image with lots of identical internal blocks (zero pages, repeated sectors).
    block = rnd_bytes(rng, 64 * 1024)
    img = bytearray()
    for i in range(160):
        img += block if i % 3 == 0 else (bytes(64 * 1024) if i % 3 == 1 else rnd_bytes(rng, 64 * 1024))
    write(f"{out}/VMs/dev-box/disk0.img", bytes(img))

    # Unique music library.
    for i in range(10 * scale):
        write(f"{out}/Music/Album {i // 4 + 1}/track-{i + 1:02d}.flac", rnd_bytes(rng, rng.randint(3, 7) * MB // 2))

    total = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(out) for f in fs)
    print(f"wrote {out}/ ({total / MB:.1f} MiB)")


if __name__ == "__main__":
    main()
