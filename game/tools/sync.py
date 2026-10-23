#!/usr/bin/env python3
"""Mirror a file-mapped Roblox place (game/ layout) into a running Roblox Studio.

Stdlib only; runnable standalone or importable as a library.

  python3 game/tools/sync.py check    --root DIR          # luau-compile --null every synced file
  python3 game/tools/sync.py manifest --root DIR          # write DIR/tools/manifest.json
  python3 game/tools/sync.py serve    --root DIR --port P # HTTP file server on 127.0.0.1
  python3 game/tools/sync.py pull     [--port P] [--no-prune] [--out FILE]
                                                          # Luau for execute_luau (Edit DM)

Mapping (same as Script Sync):
  X.server.luau -> Script, X.client.luau -> LocalScript, X.luau -> ModuleScript, dirs -> Folders.
  Roots: ServerScriptService, ReplicatedStorage, StarterPlayerScripts (StarterPlayer.StarterPlayerScripts),
  ServerStorage, StarterGui, Workspace (only those present on disk).

Library: check(root), write_manifest(root), serve_in_thread(root, port), pull_luau(port, prune=True).
"""
from __future__ import annotations

import argparse
import functools
import json
import shutil
import subprocess
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_PORT = 34873
ROOTS = [
    "ServerScriptService",
    "ReplicatedStorage",
    "StarterPlayerScripts",
    "ServerStorage",
    "StarterGui",
    "Workspace",
]
TAG = "ForgeManaged"


# ---------------------------------------------------------------------------- files / mapping

def iter_files(root: Path) -> list[Path]:
    """Every .luau file under the synced roots that exist in `root`, sorted."""
    root = Path(root)
    out: list[Path] = []
    for r in ROOTS:
        d = root / r
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.luau")):
            rel = p.relative_to(root).parts
            if any(part.startswith(".") for part in rel):
                continue
            if p.is_file():
                out.append(p)
    return out


def classify(fname: str) -> tuple[str, str]:
    """File name -> (instance name, class)."""
    if fname.endswith(".server.luau"):
        return fname[: -len(".server.luau")], "Script"
    if fname.endswith(".client.luau"):
        return fname[: -len(".client.luau")], "LocalScript"
    return fname[: -len(".luau")], "ModuleScript"


def manifest_entries(root: Path) -> list[dict]:
    root = Path(root)
    entries = []
    for p in iter_files(root):
        rel = p.relative_to(root).parts
        name, cls = classify(rel[-1])
        entries.append({
            "service": rel[0],
            "dirs": list(rel[1:-1]),
            "name": name,
            "class": cls,
            "path": "/".join(rel),
        })
    return entries


def write_manifest(root: Path) -> Path:
    """Write ROOT/tools/manifest.json and return its path."""
    root = Path(root)
    out = root / "tools" / "manifest.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest_entries(root), indent=1) + "\n")
    return out


# ---------------------------------------------------------------------------- check

def _luau_compile() -> str:
    exe = shutil.which("luau-compile")
    if not exe:
        raise RuntimeError("luau-compile not found on PATH (brew install luau)")
    return exe


def check(root: Path) -> list[tuple[str, str]]:
    """Syntax-check every synced file. Returns [(relative path, error text)] for failures."""
    root = Path(root)
    exe = _luau_compile()
    bad: list[tuple[str, str]] = []
    for p in iter_files(root):
        r = subprocess.run([exe, "--null", str(p)], capture_output=True, text=True)
        if r.returncode != 0:
            lines = [ln for ln in (r.stdout + r.stderr).splitlines()
                     if ln.strip() and not ln.startswith("Compiled ")]
            msg = "\n".join(ln.replace(str(p), p.name) for ln in lines) or f"luau-compile exit {r.returncode}"
            bad.append((p.relative_to(root).as_posix(), msg))
    return bad


# ---------------------------------------------------------------------------- serve

class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


class _Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def make_server(root: Path, port: int) -> ThreadingHTTPServer:
    handler = functools.partial(_QuietHandler, directory=str(Path(root).resolve()))
    return _Server(("127.0.0.1", port), handler)


def serve_in_thread(root: Path, port: int) -> ThreadingHTTPServer:
    """Start a file server for `root` on 127.0.0.1:port in a daemon thread.

    Call .shutdown() then .server_close() to stop. port=0 picks a free port
    (see server.server_address[1]).
    """
    srv = make_server(root, port)
    t = threading.Thread(target=srv.serve_forever, name=f"forge-sync-{port}", daemon=True)
    t.start()
    return srv


# ---------------------------------------------------------------------------- pull (Luau)

_PULL_TEMPLATE = r'''-- GENERATED by game/tools/sync.py pull_luau(port=__PORT__, prune=__PRUNE__). Do not edit by hand.
-- Run via Studio MCP execute_luau (Edit datamodel) while `sync.py serve` is running.
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local BASE = "http://127.0.0.1:__PORT__/"
local PRUNE = __PRUNE__
local TAG = "ForgeManaged"
local ROOTS = { "ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts", "ServerStorage", "StarterGui", "Workspace" }

local function rootOf(service: string): Instance?
	if service == "StarterPlayerScripts" then
		local sp = game:GetService("StarterPlayer")
		return sp:FindFirstChildOfClass("StarterPlayerScripts") or sp:FindFirstChild("StarterPlayerScripts")
	end
	local ok, svc = pcall(game.GetService, game, service)
	return if ok then svc else nil
end

local function encode(path: string): string
	return (string.gsub(path, "[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local bust = 0
local function fetch(path: string): string
	bust += 1
	local url = BASE .. encode(path) .. "?t=" .. tostring(os.clock()) .. "_" .. tostring(bust) .. "_" .. tostring(math.random(1, 1e9))
	return HttpService:GetAsync(url, true)
end

local function findScript(parent: Instance, name: string): Instance?
	for _, c in parent:GetChildren() do
		if c.Name == name and c:IsA("LuaSourceContainer") then
			return c
		end
	end
	return nil
end

local function findDir(parent: Instance, name: string): Instance?
	for _, c in parent:GetChildren() do
		if c.Name == name and not c:IsA("LuaSourceContainer") then
			return c
		end
	end
	return nil
end

local was = HttpService.HttpEnabled
HttpService.HttpEnabled = true
local ok, result = pcall(function()
	local manifest = HttpService:JSONDecode(fetch("tools/manifest.json"))
	local n, changed, pruned = 0, {}, {}
	local keep: { [Instance]: boolean } = {}
	for _, e in manifest do
		local parent = rootOf(e.service)
		if not parent then
			error("no root for service " .. tostring(e.service))
		end
		for _, d in e.dirs do
			local f = findDir(parent, d)
			if not f then
				f = Instance.new("Folder")
				f.Name = d
				f.Parent = parent
			end
			parent = f
		end
		local src = fetch(e.path)
		local inst = findScript(parent, e.name)
		if inst and inst.ClassName ~= e.class then
			inst:Destroy()
			inst = nil
		end
		local created = false
		if not inst then
			inst = Instance.new(e.class)
			inst.Name = e.name
			created = true
		end
		if (inst :: any).Source ~= src then
			(inst :: any).Source = src
			table.insert(changed, e.path)
		end
		CollectionService:AddTag(inst, TAG)
		if created then
			inst.Parent = parent
		end
		keep[inst] = true
		n += 1
	end
	if PRUNE then
		local roots = {}
		for _, s in ROOTS do
			local r = rootOf(s)
			if r then
				table.insert(roots, r)
			end
		end
		for _, inst in CollectionService:GetTagged(TAG) do
			if keep[inst] or not inst:IsA("LuaSourceContainer") then
				continue
			end
			for _, r in roots do
				if inst:IsDescendantOf(r) then
					table.insert(pruned, inst:GetFullName())
					inst:Destroy()
					break
				end
			end
		end
	end
	local msg = n .. " files, changed: " .. (if #changed > 0 then table.concat(changed, ", ") else "none")
	if #pruned > 0 then
		msg ..= "; pruned: " .. table.concat(pruned, ", ")
	end
	return msg
end)
HttpService.HttpEnabled = was
return (if ok then "OK " else "ERROR ") .. tostring(result)
'''


def pull_luau(port: int = DEFAULT_PORT, prune: bool = True) -> str:
    """Luau source for execute_luau (Edit DM) that pulls ROOT from serve_in_thread(ROOT, port)."""
    return _PULL_TEMPLATE.replace("__PORT__", str(int(port))).replace("__PRUNE__", "true" if prune else "false")


# ---------------------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(prog="sync.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("check", "manifest", "serve"):
        sp = sub.add_parser(name)
        sp.add_argument("--root", type=Path, default=default_root)
        if name == "serve":
            sp.add_argument("--port", type=int, default=DEFAULT_PORT)
    sp = sub.add_parser("pull")
    sp.add_argument("--port", type=int, default=DEFAULT_PORT)
    sp.add_argument("--no-prune", action="store_true")
    sp.add_argument("--out", type=Path, help="write to this file instead of stdout")
    a = ap.parse_args(argv)

    if a.cmd == "check":
        files = iter_files(a.root)
        try:
            bad = check(a.root)
        except RuntimeError as e:
            print(f"ERROR {e}")
            return 1
        for rel, msg in bad:
            print(f"FAIL {rel}\n{msg}")
        print(f"{'OK' if not bad else 'ERRORS'}: checked {len(files)} files, {len(bad)} failed")
        return 1 if bad else 0
    if a.cmd == "manifest":
        out = write_manifest(a.root)
        print(f"wrote {out} ({len(manifest_entries(a.root))} files)")
        return 0
    if a.cmd == "serve":
        srv = make_server(a.root, a.port)
        print(f"serving {Path(a.root).resolve()} on http://127.0.0.1:{srv.server_address[1]}/", flush=True)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            srv.server_close()
        return 0
    if a.cmd == "pull":
        src = pull_luau(a.port, prune=not a.no_prune)
        if a.out:
            a.out.write_text(src)
        else:
            sys.stdout.write(src)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
