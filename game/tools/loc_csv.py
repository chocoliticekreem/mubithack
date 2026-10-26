#!/usr/bin/env python3
"""Export the hand-written translations (game/ReplicatedStorage/Config/Translations) as a Roblox
localization CSV for the Creator Dashboard (Localization -> Translations -> upload CSV).

    python3 game/tools/loc_csv.py [--root game] [--out loc.csv] [--templates]

Columns: Key, Context, Example, Source, es, ru, pt, fr, id, th, tr, pl, uk. Plain strings only by
default: Roblox's automatic translation matches whole strings, so templates ("FIRES LEFT  {1}") are
handled in game by Controllers/LocalizationController; --templates includes them anyway.
"""
import argparse
import csv
import os
import re
import sys

LANGS = ["es", "ru", "pt", "fr", "id", "th", "tr", "pl", "uk"]
STR = r'"((?:[^"\\]|\\.)*)"'


def unq(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="game")
    ap.add_argument("--out", default="loc.csv")
    ap.add_argument("--templates", action="store_true")
    a = ap.parse_args()
    d = os.path.join(a.root, "ReplicatedStorage", "Config", "Translations")
    keys = [unq(m.group(1)) for m in re.finditer(r"^\t" + STR + r",\s*$", open(os.path.join(d, "Keys.luau"), encoding="utf-8").read(), re.M)]
    tables = {}
    for lang in LANGS:
        p = os.path.join(d, f"{lang}.luau")
        if not os.path.exists(p):
            continue
        src = open(p, encoding="utf-8").read()
        tables[lang] = {unq(m.group(1)): unq(m.group(2)) for m in re.finditer(r"^\t\[" + STR + r"\] = " + STR + r",\s*$", src, re.M)}
    cols = [l for l in LANGS if l in tables]
    n = 0
    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["Key", "Context", "Example", "Source"] + cols)
        for k in keys:
            if not a.templates and re.search(r"\{\d\}", k):
                continue
            w.writerow(["", "", "", k] + [tables[l].get(k, "") for l in cols])
            n += 1
    print(f"wrote {a.out}: {n} strings x {len(cols)} languages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
