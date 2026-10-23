#!/usr/bin/env python3
"""Build a .rbxlx place file from a game tree (stdlib only).

Usage:
  python3 game/tools/make_place.py --root game --out place/Forge.rbxlx

Scripts map the same way as sync.py (X.server.luau -> Script, X.client.luau -> LocalScript,
X.luau -> ModuleScript, dirs -> Folders). The place also gets a baseplate. Players spawn on the station's
StationSpawn pads (SquadService), so no SpawnLocation is created. After the place is open, sync.py keeps scripts up to date.
"""

from __future__ import annotations

import argparse
import itertools
from pathlib import Path
from xml.sax.saxutils import escape

SERVICES = ["ServerScriptService", "ReplicatedStorage", "ServerStorage", "StarterGui", "Workspace"]
_ref = itertools.count(1)


def _props(name: str, extra: str = "") -> str:
    return f'<Properties><string name="Name">{escape(name)}</string>{extra}</Properties>'


def _item(cls: str, name: str, children: str = "", extra: str = "") -> str:
    return f'<Item class="{cls}" referent="RBX{next(_ref)}">{_props(name, extra)}{children}</Item>'


def _cdata(s: str) -> str:
    return "<![CDATA[" + s.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def _script(path: Path) -> str:
    fname = path.name
    if fname.endswith(".server.luau"):
        cls, name = "Script", fname[: -len(".server.luau")]
    elif fname.endswith(".client.luau"):
        cls, name = "LocalScript", fname[: -len(".client.luau")]
    else:
        cls, name = "ModuleScript", fname[: -len(".luau")]
    src = f'<ProtectedString name="Source">{_cdata(path.read_text())}</ProtectedString>'
    return _item(cls, name, extra=src)


def _dir(d: Path) -> str:
    out = []
    for p in sorted(d.iterdir()):
        if p.name.startswith("."):
            continue
        if p.is_dir():
            out.append(_item("Folder", p.name, _dir(p)))
        elif p.suffix == ".luau":
            out.append(_script(p))
    return "".join(out)


def _part(cls: str, name: str, size: tuple, pos: tuple, color: int) -> str:
    x, y, z = size
    px, py, pz = pos
    extra = (
        '<bool name="Anchored">true</bool>'
        f'<Vector3 name="size"><X>{x}</X><Y>{y}</Y><Z>{z}</Z></Vector3>'
        f'<CoordinateFrame name="CFrame"><X>{px}</X><Y>{py}</Y><Z>{pz}</Z>'
        "<R00>1</R00><R01>0</R01><R02>0</R02><R10>0</R10><R11>1</R11><R12>0</R12>"
        "<R20>0</R20><R21>0</R21><R22>1</R22></CoordinateFrame>"
        f'<Color3uint8 name="Color3uint8">{color}</Color3uint8>'
    )
    return _item(cls, name, extra=extra)


def build(root: Path) -> str:
    items = []
    for svc in SERVICES:
        d = root / svc
        children = _dir(d) if d.is_dir() else ""
        if svc == "Workspace":
            children = (
                _part("Part", "Baseplate", (512, 4, 512), (0, -2, 0), 0xFF5B5B5B)
                + children
            )
        items.append(_item(svc, svc, children))
    sps = root / "StarterPlayerScripts"
    sps_xml = _item("StarterPlayerScripts", "StarterPlayerScripts", _dir(sps) if sps.is_dir() else "")
    items.append(_item("StarterPlayer", "StarterPlayer", sps_xml))
    return '<roblox version="4">' + "".join(items) + "</roblox>\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="game")
    ap.add_argument("--out", default="place/Forge.rbxlx")
    a = ap.parse_args()
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build(Path(a.root)))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
