#!/usr/bin/env python3
"""Render ANSI (truecolor) terminal output as a standalone SVG "screenshot".

    chunkmap scan demo-data --color always | python scripts/ansi_to_svg.py > docs/terminal.svg
"""
import html
import re
import sys

FG_DEFAULT = "#e2e6ee"
BG = "#0b0e14"
CHAR_W = 8.4
LINE_H = 19
PAD_X, PAD_TOP, PAD_BOTTOM = 22, 50, 18
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def parse(line: str):
    """Yield (text, color, bold, dim) runs."""
    color, bold, dim = FG_DEFAULT, False, False
    pos = 0
    for m in SGR.finditer(line):
        if m.start() > pos:
            yield line[pos : m.start()], color, bold, dim
        codes = [int(c) for c in m.group(1).split(";") if c] or [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0:
                color, bold, dim = FG_DEFAULT, False, False
            elif c == 1:
                bold = True
            elif c == 2:
                dim = True
            elif c == 38 and i + 4 < len(codes) and codes[i + 1] == 2:
                color = "#%02x%02x%02x" % tuple(codes[i + 2 : i + 5])
                i += 4
            i += 1
        pos = m.end()
    if pos < len(line):
        yield line[pos:], color, bold, dim


def main() -> None:
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    lines = [re.sub(r"\x1b\[[0-9;]*[A-Za-ln-z]|\r", "", l) for l in raw.rstrip("\n").split("\n")]
    width_chars = max((len(SGR.sub("", l)) for l in lines), default=80)
    w = int(PAD_X * 2 + width_chars * CHAR_W)
    h = int(PAD_TOP + PAD_BOTTOM + len(lines) * LINE_H)
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="chunkmap terminal output">',
        "<style>text{font-family:'JetBrains Mono','Cascadia Code',ui-monospace,Menlo,Consolas,monospace;font-size:14px;white-space:pre}</style>",
        f'<rect width="{w}" height="{h}" rx="12" fill="{BG}"/>',
        f'<rect x="0.5" y="0.5" width="{w - 1}" height="{h - 1}" rx="12" fill="none" stroke="#232c3b"/>',
        '<circle cx="22" cy="20" r="6" fill="#ff5f57"/><circle cx="42" cy="20" r="6" fill="#febc2e"/><circle cx="62" cy="20" r="6" fill="#28c840"/>',
        f'<text x="{w / 2}" y="25" text-anchor="middle" fill="#5b6578" style="font-size:12px">chunkmap scan ~/</text>',
    ]
    for n, line in enumerate(lines):
        y = PAD_TOP + n * LINE_H + 12
        spans = []
        for text, color, bold, dim in parse(line):
            attrs = f'fill="{color}"'
            if bold:
                attrs += ' font-weight="700"'
            if dim:
                attrs += ' opacity="0.6"'
            spans.append(f"<tspan {attrs}>{html.escape(text)}</tspan>")
        if spans:
            out.append(f'<text x="{PAD_X}" y="{y}" xml:space="preserve">{"".join(spans)}</text>')
    out.append("</svg>")
    sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
