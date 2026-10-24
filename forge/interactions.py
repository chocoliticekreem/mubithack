"""Static interaction audit (`forge interactions <slug>`): interactions in a game's Luau that cannot work.

The overnight Funfair Frenzy build put a "Try on costumes" ProximityPrompt on the changing-room pad that nothing
handled (Shop.luau setupPad), next to a second one Lobby.luau made, and a RESET button whose RemoteEvent no
server script listens to. The player presses E, or the button, and nothing happens. This audit finds that class
of bug from the parsed source (`luau-ast`, shipped with luau), each finding with file:line:

  prompt_no_handler     a ProximityPrompt with no Triggered/TriggerEnded connection and no
                        ProximityPromptService.PromptTriggered handler that covers it                     high
  click_no_handler      a ClickDetector with no MouseClick/RightMouseClick                                 high
  button_no_handler     a TextButton/ImageButton with no Activated/MouseButton*/TouchTap/Input* handler   medium
  remote_no_listener    FireServer with no OnServerEvent; FireClient/FireAllClients with no OnClientEvent  high
  remote_no_answer      InvokeServer with no OnServerInvoke; InvokeClient with no OnClientInvoke          high
  remote_never_fired    an OnServerEvent/OnClientEvent/On*Invoke that nothing fires or invokes            medium
  bindable_no_answer    BindableFunction:Invoke with no OnInvoke                                          high
  bindable_no_listener  BindableEvent:Fire with no Event listener (and bindable_never_fired, the reverse)  low

An object meets its handler through the same value (a local, an alias, what a helper returns, a parameter of a
local function), through its Name (FindFirstChild / WaitForChild / `x.Name` lookups anywhere in the game), or
through a generic handler (a class lookup such as FindFirstChildWhichIsA("ProximityPrompt"), a loop over
descendants, a connection on a value it cannot follow). A generic handler reaches only the container it iterates
(children / descendants / a tag) or, when it has none, the objects of its own file; objects it covers are counted
as `generic`, not as matched. Tool.Activated (same name as GuiButton.Activated) is not a button handler: a target
tested with IsA("Tool") or taken from a Backpack or a character is a tool. An object the audit cannot follow
(stored in a table, returned to callers it cannot see, passed to an unknown function) is counted as `unknown`,
never reported: this is a hard gate and must not cry wolf. A remote check it has to switch off (a listener or a
sender whose remote it cannot name) is listed in stats.suppressed with its file:line. The live journey
(forge/journey.py) checks what it cannot.

Forge's runtime and test harness files are not the game (gaps.RUNTIME_FILES); a prebuilt kit module counts only
when the game names it, and its findings say kit: true (the fixer never edits kit files).
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

LUAU_AST = "luau-ast"
KIT_DIR = "ReplicatedStorage/Kit/"
GATE_SEVERITIES = ("high", "medium")
MAX_CALL_DEPTH = 3       # helper calls followed inside each other
MAX_EVAL_DEPTH = 80      # nested expressions followed before giving up (unknown)
MAX_CALL_SITES = 400     # call sites read to bind an unbound parameter (beyond: unknown)

PROMPT, CLICK, BUTTON = "prompt", "click", "button"
FAMILY = {"ProximityPrompt": PROMPT, "ClickDetector": CLICK, "TextButton": BUTTON, "ImageButton": BUTTON}
FAMILY_CLASSES = {PROMPT: {"ProximityPrompt"}, CLICK: {"ClickDetector"},
                  BUTTON: {"GuiButton", "TextButton", "ImageButton"}}
HANDLER_EVENTS = {
    PROMPT: {"Triggered", "TriggerEnded"},
    CLICK: {"MouseClick", "RightMouseClick"},
    BUTTON: {"Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click",
             "MouseButton2Down", "MouseButton2Up", "TouchTap", "InputBegan", "InputEnded"},
}
EVENT_FAMILY = {ev: fam for fam, evs in HANDLER_EVENTS.items() for ev in evs}
BINDABLE_CLASSES = {"BindableEvent", "BindableFunction"}
CONNECT = {"Connect", "Once", "Wait", "ConnectParallel"}
FIND_NAME = {"FindFirstChild", "WaitForChild", "FindFirstAncestor", "FindFirstDescendant"}
FIND_CLASS = {"FindFirstChildOfClass", "FindFirstChildWhichIsA", "FindFirstAncestorOfClass",
              "FindFirstAncestorWhichIsA"}
FIND_CHILD_CLASS = {"FindFirstChildOfClass", "FindFirstChildWhichIsA"}  # (class, recursive?) under a container
LISTS = {"GetChildren", "GetDescendants", "GetTagged", "GetPlayers"}
SENDS = {"FireServer": "OnServerEvent", "FireClient": "OnClientEvent", "FireAllClients": "OnClientEvent",
         "InvokeServer": "OnServerInvoke", "InvokeClient": "OnClientInvoke", "Fire": "Event", "Invoke": "OnInvoke"}
LISTENS = {"OnServerEvent", "OnClientEvent", "Event"}
CALLBACKS = {"OnServerInvoke", "OnClientInvoke", "OnInvoke"}
SIGNALS = set(EVENT_FAMILY) | LISTENS | {"PromptTriggered", "PromptTriggerEnded"}
# passing an object to these does not hand it to code we cannot see
SAFE_METHODS = {"AddTag", "RemoveTag", "HasTag", "AddItem", "Create", "IsA", "IsDescendantOf", "IsAncestorOf",
                "GetFullName", "SetAttribute", "GetAttribute"}
SAFE_GLOBALS = {"typeof", "type", "tostring", "print", "warn", "assert", "error"}
SAFE_PROPS = {"Parent", "Adornee", "PrimaryPart", "Attachment0", "Attachment1", "Part0", "Part1", "CameraSubject"}
LABEL_PROPS = {"ActionText", "ObjectText", "Text"}
# (sender methods, receiver signal, forward finding, reverse finding)
PAIRS = (
    (("FireServer",), "OnServerEvent", "remote_no_listener", "remote_never_fired"),
    (("FireClient", "FireAllClients"), "OnClientEvent", "remote_no_listener", "remote_never_fired"),
    (("InvokeServer",), "OnServerInvoke", "remote_no_answer", "remote_never_fired"),
    (("InvokeClient",), "OnClientInvoke", "remote_no_answer", "remote_never_fired"),
    (("Fire",), "Event", "bindable_no_listener", "bindable_never_fired"),
    (("Invoke",), "OnInvoke", "bindable_no_answer", "bindable_never_fired"),
)
SEVERITY = {"prompt_no_handler": "high", "click_no_handler": "high", "button_no_handler": "medium",
            "remote_no_listener": "high", "remote_no_answer": "high", "remote_never_fired": "medium",
            "bindable_no_answer": "high", "bindable_no_listener": "low", "bindable_never_fired": "low"}
TOOL_EVENTS = {"Activated"}  # Tool.Activated has the same name as GuiButton.Activated
TOOL_CLASSES = {"Tool", "BackpackItem", "HopperBin"}
TOOL_SOURCES = {"Backpack", "StarterPack", "StarterGear", "Character"}
MAX_PARENT_DEPTH = 6     # parent links followed up from an object to a generic handler's container

UNK = ("unknown",)
EMPTY: frozenset = frozenset()


def luau_ast() -> str | None:
    return shutil.which(LUAU_AST)


def _line(node: dict) -> int:
    try:
        return int(str(node.get("location", "0,0")).split(",", 1)[0]) + 1
    except ValueError:
        return 0


def _q(s: str) -> str:
    return '"' + s + '"'


def parse_file(path: Path, exe: str | None = None) -> tuple[dict | None, str | None]:
    """(AST root, None) or (None, error) for one .luau file, through `luau-ast`."""
    exe = exe or luau_ast()
    if not exe:
        return None, "luau-ast not on PATH"
    try:
        res = subprocess.run([exe, str(path)], capture_output=True, text=True, encoding="utf-8", errors="replace",
                             timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"luau-ast failed: {e}"
    out = res.stdout
    start = out.find('{"root"')
    if start < 0:
        return None, (out.strip() or res.stderr.strip() or "no AST")[:300]
    errors = out[:start] + res.stderr
    if "Parse errors were encountered" in errors:  # the AST of a file that does not parse is partial
        return None, " ".join(errors.split("{", 1)[0].split())[:300]
    try:
        return json.loads(out[start:])["root"], None
    except (ValueError, KeyError) as e:
        return None, f"unreadable AST: {e}"


def _skipped(rel: str) -> bool:
    from forge.gaps import RUNTIME_FILES

    name = rel.rsplit("/", 1)[-1]
    return rel.startswith(("tools/", "tests/")) or any(name.startswith(r) for r in RUNTIME_FILES)


def _stem(rel: str) -> str:
    name = rel.rsplit("/", 1)[-1]
    for suffix in (".server.luau", ".client.luau", ".luau"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


class _Env:
    """The binding of one helper call: its parameters -> the caller's argument expressions, and the creation
    chain so far (call sites from the outermost in, so each `mk("TextButton")` call is its own object).
    `serial` keys the memo: id() of a collected env is reused by the next one."""

    _next = 0

    def __init__(self, fkey: str, bind: dict, chain: tuple):
        self.fkey, self.bind, self.chain = fkey, bind, chain
        _Env._next += 1
        self.serial = _Env._next


class _File:
    def __init__(self, rel: str, root: dict, kit: bool):
        self.rel, self.root, self.kit = rel, root, kit
        self.locals: dict[str, dict] = {}
        self.assigns: dict[str, list] = {}
        self.fields: dict[tuple, list] = {}
        self.funcs: dict[str, dict] = {}
        self.local_funcs: dict[str, str] = {}
        self.field_funcs: dict[tuple, str] = {}
        self.parent: dict[int, dict] = {}
        self.uses: dict[str, list] = {}
        self.calls: list[tuple[dict, str | None]] = []
        self.props: list[tuple[dict, dict]] = []
        self.returns: list[dict] = []
        self.dynamic: set[str] = set()  # locals filled as t[k] = v with a computed key (tables keyed by name)
        self.loops: dict[str, list] = {}  # for-in variable -> the expressions it iterates
        self.tools: set[str] = set()  # locals tested with IsA("Tool") / ClassName == "Tool"
        self._index()

    def lkey(self, decl: dict) -> str:
        return f"{self.rel}#{decl.get('location')}"

    def fkey(self, fn: dict) -> str:
        return f"{self.rel}@{fn.get('location')}"

    def _declare(self, decl: dict, kind: str, func: str | None, index: int = 0) -> str:
        k = self.lkey(decl)
        self.locals[k] = {"name": decl.get("name"), "line": _line(decl), "kind": kind, "func": func, "index": index}
        return k

    def path_of(self, n: dict) -> tuple | None:
        """(root, "a.b") for an index chain rooted at a local or a global, else None."""
        parts = []
        while n.get("type") in ("AstExprIndexName", "AstExprIndexExpr"):
            if n["type"] == "AstExprIndexName":
                parts.append(str(n.get("index")))
            else:
                idx = n.get("index") or {}
                if idx.get("type") != "AstExprConstantString":
                    return None
                parts.append(str(idx.get("value")))
            n = n.get("expr") or {}
        if n.get("type") == "AstExprLocal":
            root = ("L", self.lkey(n["local"]))
        elif n.get("type") == "AstExprGlobal":
            root = ("G", n.get("global"))
        else:
            return None
        return root, ".".join(reversed(parts))

    def _index(self) -> None:
        stack: list[tuple[Any, dict | None, str | None]] = [(self.root, None, None)]
        while stack:
            node, parent, fk = stack.pop()
            if isinstance(node, list):
                for x in node:
                    stack.append((x, parent, fk))
                continue
            if not isinstance(node, dict):
                continue
            t = node.get("type")
            if t is None:
                continue
            if parent is not None:
                self.parent[id(node)] = parent
            if t == "AstExprLocal":
                self.uses.setdefault(self.lkey(node["local"]), []).append(node)
                continue
            if t == "AstLocal" or t.startswith("AstType"):
                continue
            inner = fk
            if t == "AstExprFunction":
                inner = self.fkey(node)
                info = {"node": node, "parent": fk, "returns": [], "self": None, "params": []}
                if node.get("self"):
                    info["self"] = self._declare(node["self"], "self", inner)
                info["params"] = [self._declare(a, "param", inner, i) for i, a in enumerate(node.get("args") or [])]
                self.funcs[inner] = info
            elif t == "AstStatLocal":
                values = node.get("values") or []
                for i, var in enumerate(node.get("vars") or []):
                    k = self._declare(var, "local", fk)
                    if i < len(values):
                        self.assigns.setdefault(k, []).append(values[i])
                    elif i == 1 and len(values) == 1 and _pcall_target(values[0]) is not None:
                        self.assigns.setdefault(k, []).append(_pcall_target(values[0]))
            elif t == "AstStatAssign":
                values = node.get("values") or []
                for i, var in enumerate(node.get("vars") or []):
                    value = values[i] if i < len(values) else None
                    if value is None:
                        continue
                    if var.get("type") == "AstExprLocal":
                        self.assigns.setdefault(self.lkey(var["local"]), []).append(value)
                    elif var.get("type") in ("AstExprIndexName", "AstExprIndexExpr"):
                        p = self.path_of(var)
                        if p:
                            self.fields.setdefault(p, []).append(value)
                        elif var.get("type") == "AstExprIndexExpr" and (var.get("expr") or {}).get("type") == "AstExprLocal":
                            self.dynamic.add(self.lkey(var["expr"]["local"]))
                        self.props.append((var, value))
            elif t == "AstStatLocalFunction":
                k = self._declare(node["name"], "func", fk)
                self.local_funcs[k] = self.fkey(node["func"])
            elif t == "AstStatFunction":
                name = node.get("name") or {}
                if name.get("type") == "AstExprLocal":
                    self.local_funcs[self.lkey(name["local"])] = self.fkey(node["func"])
                else:
                    p = self.path_of(name)
                    if p:
                        self.field_funcs[p] = self.fkey(node["func"])
            elif t == "AstStatFor":
                self._declare(node["var"], "loop", fk)
            elif t == "AstStatForIn":
                for var in node.get("vars") or []:
                    self.loops[self._declare(var, "loop", fk)] = list(node.get("values") or [])
            elif t == "AstStatReturn":
                first = (node.get("list") or [None])[0]
                if first is not None:
                    (self.funcs[fk]["returns"] if fk in self.funcs else self.returns).append(first)
            elif t == "AstExprCall":
                self.calls.append((node, fk))
                fn, args = node.get("func") or {}, node.get("args") or []
                if node.get("self") and fn.get("type") == "AstExprIndexName" and fn.get("index") == "IsA" and args \
                        and args[0].get("type") == "AstExprConstantString" and args[0].get("value") in TOOL_CLASSES \
                        and (fn.get("expr") or {}).get("type") == "AstExprLocal":
                    self.tools.add(self.lkey(fn["expr"]["local"]))
            elif t == "AstExprBinary" and node.get("op") in ("CompareEq", "CompareNe"):
                sides = [node.get("left") or {}, node.get("right") or {}]
                for a, b in (sides, sides[::-1]):
                    if a.get("type") == "AstExprIndexName" and a.get("index") == "ClassName" \
                            and (a.get("expr") or {}).get("type") == "AstExprLocal" \
                            and b.get("type") == "AstExprConstantString" and b.get("value") in TOOL_CLASSES:
                        self.tools.add(self.lkey(a["expr"]["local"]))
            for key, child in node.items():
                if key not in ("type", "location") and isinstance(child, (dict, list)):
                    stack.append((child, node, inner))


class Game:
    """Every audited file of one game, parsed, plus the evaluator that follows values between them."""

    def __init__(self, files: dict[str, _File]):
        self.files = files
        self.by_stem: dict[str, list[_File]] = {}
        for f in files.values():
            if f.rel.endswith(".luau") and not f.rel.endswith((".server.luau", ".client.luau")):
                self.by_stem.setdefault(_stem(f.rel), []).append(f)
        self.func_file: dict[str, _File] = {k: f for f in files.values() for k in f.funcs}
        self.tables: dict[int, tuple[dict, _File]] = {}
        self.sites: dict[str, tuple[dict, _File]] = {}  # site key -> (call node, file)
        self.memo: dict[tuple, frozenset] = {}
        self.depth = 0
        self.call_depth = 0
        self._sites: dict[str, list] | None = None
        self._records_by_key: dict[str, set[str]] | None = None

    # ------------------------------------------------------------------ values
    # ("new", chain, class) | ("named", name) | ("cls", class) | ("str", s) | ("tab", id) | ("mod", stem)
    # | ("fn", key) | ("svc", name) | ("unknown",)

    def ev(self, n: dict | None, f: _File, env: _Env | None = None) -> frozenset:
        if not isinstance(n, dict):
            return EMPTY
        key = (id(n), env.serial if env is not None else 0)
        got = self.memo.get(key)
        if got is not None:
            return got
        if self.depth > MAX_EVAL_DEPTH:
            return frozenset({UNK})
        self.memo[key] = EMPTY  # a cycle reads as nothing
        self.depth += 1
        try:
            out = frozenset(self._ev(n, f, env))
        finally:
            self.depth -= 1
        self.memo[key] = out
        return out

    def _ev(self, n: dict, f: _File, env: _Env | None) -> set:
        t = n.get("type")
        if t == "AstExprConstantString":
            return {("str", str(n.get("value")))}
        if t in ("AstExprGroup", "AstExprTypeAssertion"):
            return set(self.ev(n.get("expr"), f, env))
        if t == "AstExprBinary":
            if n.get("op") == "Or":
                return set(self.ev(n.get("left"), f, env) | self.ev(n.get("right"), f, env))
            if n.get("op") == "And":
                return set(self.ev(n.get("right"), f, env))
            return set()
        if t == "AstExprIfElse":
            return set(self.ev(n.get("trueExpr"), f, env) | self.ev(n.get("falseExpr"), f, env))
        if t == "AstExprTable":
            self.tables[id(n)] = (n, f)
            return {("tab", id(n))}
        if t == "AstExprFunction":
            return {("fn", f.fkey(n))}
        if t == "AstExprGlobal":
            g = n.get("global")
            if g == "game":
                return {("svc", "game")}
            if g in ("workspace", "Workspace"):
                return {("svc", "Workspace")}
            if g == "script":
                return {("named", "script")}
            return {UNK}
        if t == "AstExprLocal":
            return self._local(n["local"], f, env)
        if t == "AstExprIndexName":
            return self._index(n.get("expr"), str(n.get("index")), f, env, n)
        if t == "AstExprIndexExpr":
            keys = [v[1] for v in self.ev(n.get("index"), f, env) if v[0] == "str"]
            if not keys:
                return {UNK}
            out: set = set()
            for k in keys:
                out |= self._index(n.get("expr"), k, f, env, n)
            return out
        if t == "AstExprCall":
            return self._call(n, f, env)
        if t == "AstExprVarargs":
            return {UNK}
        return set()

    def _inside(self, local: dict, fkey: str, f: _File) -> bool:
        cur = local.get("func")
        while cur is not None:
            if cur == fkey:
                return True
            cur = (f.funcs.get(cur) or {}).get("parent")
        return False

    def _local(self, decl: dict, f: _File, env: _Env | None) -> set:
        lk = f.lkey(decl)
        info = f.locals.get(lk)
        if info is None:
            return {UNK}
        if env is not None and lk in env.bind:
            arg, af, aenv = env.bind[lk]
            return set(self.ev(arg, af, aenv)) if arg is not None else set()
        kind = info["kind"]
        if kind == "func":
            return {("fn", f.local_funcs[lk])} if lk in f.local_funcs else {UNK}
        if kind == "loop":
            return {UNK}
        if kind in ("param", "self"):
            sites = self.call_sites(info["func"])
            if not sites:
                return {UNK}
            out: set = set() if len(sites) <= MAX_CALL_SITES else {UNK}
            for call, cf in sites[:MAX_CALL_SITES]:
                arg = self._arg_for(call, lk, info["func"])
                if arg is not None:
                    out |= self.ev(arg, cf, None)
            return out or {UNK}
        fenv = env if env is not None and self._inside(info, env.fkey, f) else None
        out = set()
        for v in f.assigns.get(lk, ()):
            out |= self.ev(v, f, fenv)
        if lk in f.local_funcs:
            out.add(("fn", f.local_funcs[lk]))
        return out

    def _records(self, tab_id: int, k: str) -> set:
        tn, tf = self.tables.get(tab_id, (None, None))
        out: set = set()
        for item in (tn or {}).get("items") or []:
            key = item.get("key") or {}
            if item.get("kind") == "record" and key.get("value") == k:
                out |= self.ev(item.get("value"), tf, None)
        return out

    def export(self, mf: _File, k: str) -> set:
        """What module `mf` exports as `k`: `M.k = v` / `function M.k` on the returned table, or a record of it."""
        out: set = set()
        for r in mf.returns:
            if r.get("type") == "AstExprLocal":
                root = ("L", mf.lkey(r["local"]))
                for v in mf.fields.get((root, k), ()):
                    out |= self.ev(v, mf, None)
                if (root, k) in mf.field_funcs:
                    out.add(("fn", mf.field_funcs[(root, k)]))
                for v in mf.assigns.get(root[1], ()):
                    if v.get("type") == "AstExprTable":
                        self.ev(v, mf, None)
                        out |= self._records(id(v), k)
            elif r.get("type") == "AstExprTable":
                self.ev(r, mf, None)
                out |= self._records(id(r), k)
        return out

    def _index(self, base_node: dict | None, k: str, f: _File, env: _Env | None, node: dict | None) -> set:
        base = self.ev(base_node, f, env)
        out: set = set()
        p = f.path_of(node) if node is not None else None
        if p is not None:
            for v in f.fields.get(p, ()):
                out |= self.ev(v, f, None)
            if p in f.field_funcs:
                out.add(("fn", f.field_funcs[p]))
        dynamic = (base_node or {}).get("type") == "AstExprLocal" and f.lkey(base_node["local"]) in f.dynamic
        for b in base:
            if b[0] == "tab":
                rec = self._records(b[1], k)
                out |= rec
                if not rec and dynamic:  # remotes[name] = r in a loop: remotes.Toast is the one named Toast,
                    # or the one a config record maps that key to (Config.Remotes = {Reset = "ResetToCheckpoint"})
                    out.add(("named", k))
                    out |= {("named", v) for v in self.string_records().get(k, ())}
            elif b[0] == "mod":
                for mf in self.by_stem.get(b[1], ()):
                    out |= self.export(mf, k)
            elif b[0] == "svc":
                out.add(("svc", k) if b[1] == "game" else ("named", k))
            elif b[0] in ("named", "new", "cls"):
                out.add(("named", k))
        return out or {UNK}

    def string_records(self) -> dict[str, set[str]]:
        """key -> the constant strings table records anywhere in the game map it to ({Reset = "ResetToCheckpoint"})."""
        if self._records_by_key is None:
            out: dict[str, set[str]] = {}
            stack: list[Any] = [v for f in self.files.values() for v in
                                [*f.returns, *(x for vs in f.assigns.values() for x in vs),
                                 *(x for vs in f.fields.values() for x in vs)]]
            while stack:
                n = stack.pop()
                if not isinstance(n, dict) or n.get("type") != "AstExprTable":
                    continue
                for item in n.get("items") or []:
                    key, value = (item.get("key") or {}).get("value"), item.get("value") or {}
                    if item.get("kind") == "record" and key and value.get("type") == "AstExprConstantString":
                        out.setdefault(str(key), set()).add(str(value.get("value")))
                    stack.append(value)
            self._records_by_key = out
        return self._records_by_key

    def _strs(self, n: dict | None, f: _File, env: _Env | None) -> list[str]:
        return [v[1] for v in self.ev(n, f, env) if v[0] == "str"]

    def _heuristic(self, args: list, f: _File, env: _Env | None) -> set:
        """An unknown call such as getRemote("Buy") or Net:Get("Buy"): its string arguments are likely names."""
        out = {("named", s) for a in args for s in self._strs(a, f, env)}
        return out or {UNK}

    def _call(self, n: dict, f: _File, env: _Env | None) -> set:
        fn = n.get("func") or {}
        args = n.get("args") or []
        if fn.get("type") == "AstExprIndexName":
            m = str(fn.get("index"))
            obj = fn.get("expr") or {}
            if m == "new" and obj.get("type") == "AstExprGlobal" and obj.get("global") == "Instance":
                classes = self._strs(args[0], f, env) if args else []
                if not classes:
                    return {UNK}
                chain = (env.chain if env is not None else ()) + (self.site_key(n, f),)
                return {("new", chain, c) for c in classes}
            if n.get("self"):
                first = self._strs(args[0], f, env) if args else []
                if m in FIND_NAME:
                    return {("named", s) for s in first} or {UNK}
                if m in FIND_CLASS:
                    return {("cls", s) for s in first} or {UNK}
                if m == "GetService":
                    return {("svc", s) for s in first} or {UNK}
                if m == "Clone":
                    return set(self.ev(obj, f, env))
                if m in LISTS:
                    return {UNK}
                out: set = set()
                for b in self.ev(obj, f, env):
                    targets: set = set()
                    if b[0] == "mod":
                        for mf in self.by_stem.get(b[1], ()):
                            targets |= self.export(mf, m)
                    elif b[0] == "tab":
                        targets |= self._records(b[1], m)
                    for c in targets:
                        if c[0] == "fn":
                            out |= self.apply(c[1], n, f, env)
                return out or self._heuristic(args, f, env)
        if fn.get("type") == "AstExprGlobal" and fn.get("global") == "require":
            out = {("mod", v[1]) for v in (self.ev(args[0], f, env) if args else ()) if v[0] == "named"}
            return out or {UNK}
        callee = self.ev(fn, f, env)
        fns = [c for c in callee if c[0] == "fn"]
        if not fns:
            return self._heuristic(args, f, env)
        out = set()
        for c in fns:
            out |= self.apply(c[1], n, f, env)
        return out

    def _positional(self, call: dict) -> list:
        fn = call.get("func") or {}
        lead = [fn.get("expr")] if call.get("self") and fn.get("type") == "AstExprIndexName" else []
        return lead + list(call.get("args") or [])

    def _params(self, info: dict) -> list[str]:
        return ([info["self"]] if info.get("self") else []) + list(info["params"])

    def _arg_for(self, call: dict, lk: str, fkey: str) -> dict | None:
        ff = self.func_file.get(fkey)
        info = ff.funcs.get(fkey) if ff else None
        if info is None:
            return None
        params, pos = self._params(info), self._positional(call)
        i = params.index(lk) if lk in params else None
        return pos[i] if i is not None and i < len(pos) else None

    def apply(self, fkey: str, call: dict, cf: _File, cenv: _Env | None) -> set:
        """The values a call to function `fkey` returns, its parameters bound to the call's arguments."""
        ff = self.func_file.get(fkey)
        info = ff.funcs.get(fkey) if ff else None
        if info is None or self.call_depth >= MAX_CALL_DEPTH:
            return {UNK}
        params, pos = self._params(info), self._positional(call)
        bind = {p: (pos[i] if i < len(pos) else None, cf, cenv) for i, p in enumerate(params)}
        env = _Env(fkey, bind, (cenv.chain if cenv is not None else ()) + (self.site_key(call, cf),))
        self.call_depth += 1
        try:
            out: set = set()
            for r in info["returns"]:
                out |= self.ev(r, ff, env)
            return out
        finally:
            self.call_depth -= 1

    def site_key(self, n: dict, f: _File) -> str:
        key = f"{f.rel}:{_line(n)}:{n.get('location')}"
        self.sites.setdefault(key, (n, f))
        return key

    # ------------------------------------------------------------------ call sites of a function (syntactic)

    def call_sites(self, fkey: str) -> list[tuple[dict, _File]]:
        if self._sites is None:
            self._sites = self._all_call_sites()
        return self._sites.get(fkey, [])

    def _all_call_sites(self) -> dict[str, list]:
        out: dict[str, list] = {}
        mods: dict[str, set[str]] = {}  # file rel -> local keys holding require(<that module>)
        for f in self.files.values():
            for lk, values in f.assigns.items():
                for v in values:
                    stem = _require_stem(v)
                    if stem:
                        for mf in self.by_stem.get(stem, ()):
                            mods.setdefault(mf.rel, set()).add(lk)
        for f in self.files.values():
            for call, _ in f.calls:
                fn = call.get("func") or {}
                if fn.get("type") == "AstExprLocal":
                    fk = f.local_funcs.get(f.lkey(fn["local"]))
                    if fk:
                        out.setdefault(fk, []).append((call, f))
                elif fn.get("type") == "AstExprIndexName":
                    p = f.path_of(fn)
                    if p and p in f.field_funcs:
                        out.setdefault(f.field_funcs[p], []).append((call, f))
                        continue
                    base = fn.get("expr") or {}
                    if base.get("type") == "AstExprLocal":
                        lk = f.lkey(base["local"])
                        for mrel, holders in mods.items():
                            if lk in holders:
                                mf = self.files[mrel]
                                for r in mf.returns:
                                    if r.get("type") == "AstExprLocal":
                                        fk = mf.field_funcs.get((("L", mf.lkey(r["local"])), str(fn.get("index"))))
                                        if fk:
                                            out.setdefault(fk, []).append((call, f))
        return out


def _pcall_target(call: dict) -> dict | None:
    """`pcall(f, a, b)` -> a call node f(a, b): what `local ok, x = pcall(...)` puts in x."""
    fn = call.get("func") or {}
    args = call.get("args") or []
    if call.get("type") != "AstExprCall" or fn.get("type") != "AstExprGlobal" or fn.get("global") != "pcall" \
            or not args:
        return None
    return {"type": "AstExprCall", "location": call.get("location"), "func": args[0], "args": args[1:],
            "self": False}


def _require_stem(v: dict) -> str | None:
    """`require(...WaitForChild("X"))` / `require(script.Parent.X)` -> "X" (syntactic, for call sites)."""
    while v.get("type") in ("AstExprGroup", "AstExprTypeAssertion"):
        v = v.get("expr") or {}
    fn = v.get("func") or {}
    if v.get("type") != "AstExprCall" or fn.get("type") != "AstExprGlobal" or fn.get("global") != "require":
        return None
    a = (v.get("args") or [None])[0] or {}
    while a.get("type") in ("AstExprGroup", "AstExprTypeAssertion"):
        a = a.get("expr") or {}
    if a.get("type") == "AstExprIndexName":
        return str(a.get("index"))
    if a.get("type") == "AstExprCall":
        args = a.get("args") or []
        if args and args[0].get("type") == "AstExprConstantString":
            return str(args[0].get("value"))
    return None


# ---------------------------------------------------------------------------------------------- the audit


class _Audit:
    def __init__(self, game: Game):
        self.g = game
        self.visiting: set[str] = set()
        self.names: dict[tuple, set[str]] = {}
        self.labels: dict[tuple, set] = {}  # chain -> {(prop, text)}
        self.ident: dict[tuple, set[str]] = {}
        self.parents: dict[tuple, set] = {}  # chain -> the values its Parent is set to
        self.inert: set[tuple] = set()  # zero-size buttons: not controls (a Modal one that only frees the mouse)

    # -------------------------------------------------------- does every flow of a value stay visible?

    def ctx_safe(self, node: dict, f: _File, depth: int = 0) -> bool:
        p = f.parent.get(id(node))
        if p is None:
            return True
        t = p.get("type")
        if t in ("AstExprGroup", "AstExprTypeAssertion"):
            return self.ctx_safe(p, f, depth)
        if t == "AstExprBinary":
            return self.ctx_safe(p, f, depth) if p.get("op") in ("Or", "And") else True
        if t == "AstExprIfElse":
            return True if node is p.get("condition") else self.ctx_safe(p, f, depth)
        if t in ("AstExprUnary", "AstStatExpr", "AstStatIf", "AstStatWhile", "AstStatRepeat", "AstStatCompoundAssign",
                 "AstExprInterpString", "AstExprIndexExpr"):
            return True
        if t == "AstStatLocal":
            values, var_list = p.get("values") or [], p.get("vars") or []
            i = next((j for j, v in enumerate(values) if v is node), None)
            if i is None or i >= len(var_list):
                return i is not None
            return self.local_safe(f.lkey(var_list[i]), f, depth)
        if t == "AstStatAssign":
            values, var_list = p.get("values") or [], p.get("vars") or []
            i = next((j for j, v in enumerate(values) if v is node), None)
            if i is None:
                return True  # an assignment target, not a flow
            var = var_list[i] if i < len(var_list) else None
            if var is None:
                return True
            if var.get("type") == "AstExprLocal":
                return self.local_safe(f.lkey(var["local"]), f, depth)
            return var.get("type") == "AstExprIndexName" and var.get("index") in SAFE_PROPS
        if t == "AstExprCall":
            return self._call_safe(node, p, f, depth)
        if t == "AstExprIndexName":
            return self._member_safe(p, f)
        return False  # returned, stored in a table, ...

    def _call_safe(self, node: dict, call: dict, f: _File, depth: int) -> bool:
        fn = call.get("func") or {}
        if node is fn:
            return True
        if fn.get("type") == "AstExprIndexName":
            if fn.get("index") == "new" and (fn.get("expr") or {}).get("global") == "Instance":
                return True
            if fn.get("index") in SAFE_METHODS:
                return True
        if fn.get("type") == "AstExprGlobal" and fn.get("global") in SAFE_GLOBALS:
            return True
        if depth >= MAX_CALL_DEPTH:
            return False
        pos = self.g._positional(call)
        i = next((j for j, a in enumerate(pos) if a is node), None)
        fns = [c[1] for c in self.g.ev(fn, f, None) if c[0] == "fn"]
        if i is None or not fns:
            return False
        for fk in fns:
            ff = self.g.func_file.get(fk)
            info = ff.funcs.get(fk) if ff else None
            if info is None:
                return False
            params = self.g._params(info)
            if i >= len(params) or not self.local_safe(params[i], ff, depth + 1):
                return False
        return True

    def _member_safe(self, p: dict, f: _File) -> bool:
        gp = f.parent.get(id(p)) or {}
        if gp.get("type") == "AstExprCall" and gp.get("func") is p:
            return True  # obj:Method(...)
        if gp.get("type") == "AstStatAssign" and any(v is p for v in gp.get("vars") or []):
            return True  # obj.X = v
        if p.get("index") in SIGNALS:
            return gp.get("type") == "AstExprIndexName" and gp.get("index") in CONNECT
        return True  # a property read

    def local_safe(self, lk: str, f: _File, depth: int) -> bool:
        if lk in self.visiting:
            return True
        self.visiting.add(lk)
        try:
            return all(self.ctx_safe(u, f, depth) for u in f.uses.get(lk, ()))
        finally:
            self.visiting.discard(lk)

    # -------------------------------------------------------- facts about created objects

    def _chains(self, vals: frozenset) -> list[tuple]:
        return [v[1] for v in vals if v[0] == "new"]

    def _of(self, table: dict[tuple, set], chain: tuple) -> set:
        out: set = set()
        for i in range(len(chain)):
            out |= table.get(chain[i:], set())
        return out

    def collect_facts(self) -> None:
        """Names, labels (ActionText / Text), identity strings (attributes, tags) and parents of created objects."""
        g = self.g
        for f in g.files.values():
            for target, value in f.props:
                prop = target.get("index") if target.get("type") == "AstExprIndexName" else None
                if prop == "Parent":
                    parent = g.ev(value, f, None)
                    for chain in self._chains(g.ev(target.get("expr"), f, None)):
                        self.parents.setdefault(chain, set()).update(parent)
                    continue
                if prop == "Size" and _zero_size(value):
                    self.inert.update(self._chains(g.ev(target.get("expr"), f, None)))
                    continue
                if prop not in ("Name",) and prop not in LABEL_PROPS:
                    continue
                strs = g._strs(value, f, None)
                for chain in self._chains(g.ev(target.get("expr"), f, None)):
                    if prop == "Name":
                        self.names.setdefault(chain, set()).update(strs)
                    else:
                        self.labels.setdefault(chain, set()).update((prop, x) for x in strs)
                    self.ident.setdefault(chain, set()).update(strs)
            for call, _ in f.calls:
                fn = call.get("func") or {}
                args = call.get("args") or []
                if fn.get("type") == "AstExprIndexName" and fn.get("index") == "new" and len(args) > 1 \
                        and (fn.get("expr") or {}).get("global") == "Instance":  # Instance.new(class, parent)
                    parent = g.ev(args[1], f, None)
                    for chain in self._chains(g.ev(call, f, None)):
                        self.parents.setdefault(chain, set()).update(parent)
                if fn.get("type") != "AstExprIndexName" or not call.get("self"):
                    continue
                m = fn.get("index")
                if m == "SetAttribute" and args:
                    strs = g._strs(args[0], f, None) + (g._strs(args[1], f, None) if len(args) > 1 else [])
                    for chain in self._chains(g.ev(fn.get("expr"), f, None)):
                        self.ident.setdefault(chain, set()).update(strs)
                elif m == "AddTag" and len(args) >= 2:  # CollectionService:AddTag(obj, "Tag")
                    for chain in self._chains(g.ev(args[0], f, None)):
                        self.ident.setdefault(chain, set()).update(g._strs(args[1], f, None))
                elif m == "AddTag" and args:  # obj:AddTag("Tag")
                    for chain in self._chains(g.ev(fn.get("expr"), f, None)):
                        self.ident.setdefault(chain, set()).update(g._strs(args[0], f, None))

    def chain_names(self, chain: tuple) -> set[str]:
        """The names of one created object. Made by a helper (remote("Toast")), its own call's string arguments
        name it: the helper's `r.Name = name` read alone would give every remote it makes every name."""
        exact = set(self.names.get(chain, set()))
        if len(chain) > 1 and chain[0] in self.g.sites:
            call, f = self.g.sites[chain[0]]
            own = {s for a in call.get("args") or [] if a.get("type") != "AstExprTable"
                   for s in self.g._strs(a, f, None)}
            own |= self.call_names(call, f, "")[0]
            if own:
                return exact | own
        return exact | self._of(self.names, chain)

    def call_names(self, call: dict, f: _File, cls: str) -> tuple[set[str], set[str]]:
        """A creation through a helper: its string arguments (not the class) and a {Name = ...} / {Text = ...}
        table argument name and label it."""
        names, labels = set(), set()
        for a in call.get("args") or []:
            if a.get("type") == "AstExprTable":
                for item in a.get("items") or []:
                    key = (item.get("key") or {}).get("value")
                    strs = self.g._strs(item.get("value"), f, None)
                    if key == "Name":
                        names.update(strs)
                    elif key in LABEL_PROPS:
                        labels.update((key, x) for x in strs)
            else:
                labels.update(("Text", x) for x in self.g._strs(a, f, None) if x != cls)
        return names, labels

    # -------------------------------------------------------- generic handlers: what they can reach

    def origin(self, local: dict, f: _File) -> tuple | None:
        """Where a loop variable, callback parameter or local gets its object: ("in", container node, deep) for
        children / descendants of a container, ("tagged", [tag nodes]), ("character",) for a CharacterAdded
        parameter, or None."""
        lk = f.lkey(local)
        info = f.locals.get(lk) or {}
        kind = info.get("kind")
        if kind == "loop":
            values = f.loops.get(lk) or []
            mc = _method_call(_unwrap_iter(values[0] if values else None))
            if mc and mc[0] in ("GetChildren", "GetDescendants"):
                return ("in", mc[1], mc[0] == "GetDescendants")
            if mc and mc[0] == "GetTagged":
                return ("tagged", mc[2][-1:])
            return None
        if kind == "param" and info.get("index") == 0:
            return self._callback_origin(info["func"], f)
        if kind == "local":
            for v in f.assigns.get(lk, ()):
                for mc in _calls_in(v):
                    if mc[0] in FIND_CHILD_CLASS:
                        return ("in", mc[1], len(mc[2]) > 1)
        return None

    def _callback_origin(self, fkey: str, f: _File) -> tuple | None:
        """The first parameter of a function connected to X.ChildAdded / X.DescendantAdded / CharacterAdded /
        CollectionService:GetInstanceAddedSignal(tag), as a lambda or a local function."""
        node = (f.funcs.get(fkey) or {}).get("node")
        connects = []
        call = f.parent.get(id(node)) if node else None
        if call and call.get("type") == "AstExprCall" and any(x is node for x in call.get("args") or []):
            connects.append(call)
        for c, _ in f.calls:
            first = (c.get("args") or [None])[0] or {}
            if first.get("type") == "AstExprLocal" and f.local_funcs.get(f.lkey(first["local"])) == fkey:
                connects.append(c)
        for c in connects:
            mc = _method_call(c)
            if not mc or mc[0] not in CONNECT or mc[1].get("type") != "AstExprIndexName":
                continue
            sig, src = str(mc[1].get("index")), mc[1].get("expr") or {}
            if sig in ("ChildAdded", "ChildRemoved"):
                return ("in", src, False)
            if sig in ("DescendantAdded", "DescendantRemoving"):
                return ("in", src, True)
            if sig in ("CharacterAdded", "CharacterAppearanceLoaded"):
                return ("character",)
            inner = _method_call(src)
            if inner and inner[0] == "GetInstanceAddedSignal":
                return ("tagged", inner[2][:1])
        return None

    def is_tool(self, target: dict | None, f: _File) -> bool:
        """The object behind `target` is a Tool: tested with IsA("Tool"), or taken from a Backpack or a character."""
        root = _root_local(target)
        if root is None:
            return False
        if f.lkey(root["local"]) in f.tools:
            return True
        o = self.origin(root["local"], f)
        if not o or o[0] != "in":
            return False
        src = o[1]
        if _last_name(src) in TOOL_SOURCES or any(v[0] == "named" and v[1] in TOOL_SOURCES
                                                  for v in self.g.ev(src, f, None)):
            return True
        sroot = _root_local(src)
        return sroot is not None and sroot is src and (self.origin(sroot["local"], f) or (None,))[0] == "character"

    def scope(self, target: dict | None, f: _File) -> tuple:
        """What a generic handler on `target` can reach: ("in", container values, deep), ("tagged", tags), or
        ("file", rel) when it has no container (a value the audit cannot follow covers its own file only)."""
        for mc in _calls_in(target):  # pad:FindFirstChildWhichIsA("ProximityPrompt").Triggered
            if mc[0] in FIND_CHILD_CLASS:
                return ("in", self.g.ev(mc[1], f, None), len(mc[2]) > 1)
        root = _root_local(target)
        o = self.origin(root["local"], f) if root is not None and root is target else None
        if o and o[0] == "in":
            return ("in", self.g.ev(o[1], f, None), o[2])
        if o and o[0] == "tagged":
            return ("tagged", frozenset(s for n in o[1] for s in self.g._strs(n, f, None)))
        return ("file", f.rel)

    def within(self, chain: tuple, scope: tuple, cfile: str, depth: int = 0) -> bool:
        """Can a generic handler with this scope reach the object made at `chain` (in file `cfile`)? An unknown
        parent may be inside the container: yes."""
        if scope[0] == "all":
            return True
        if scope[0] == "file":
            return cfile == scope[1]
        if scope[0] == "tagged":
            return bool(scope[1] & self._of(self.ident, chain))
        cont, deep = scope[1], scope[2]
        if not cont or UNK in cont:
            return True  # a container it cannot follow may hold anything of the family
        parents = self._of(self.parents, chain)
        if not parents or UNK in parents or _meet(parents, cont):
            return True
        if not deep or depth >= MAX_PARENT_DEPTH:
            return False
        for p in parents:
            if p[0] in ("named", "cls"):
                return True  # an ancestor found by name may be inside the container
            if p[0] == "new" and self.within(p[1], scope, cfile, depth + 1):
                return True
        return False


def _zero_size(value: dict) -> bool:
    """UDim2.new() / UDim2.fromOffset(0, 0): nothing to click (a Modal button that only frees the mouse)."""
    fn = value.get("func") or {}
    if value.get("type") != "AstExprCall" or fn.get("type") != "AstExprIndexName" \
            or (fn.get("expr") or {}).get("global") != "UDim2" or fn.get("index") not in ("new", "fromOffset", "fromScale"):
        return False
    args = value.get("args") or []
    return all(a.get("type") == "AstExprConstantNumber" and a.get("value") == 0 for a in args)


def _method_call(e: dict | None) -> tuple[str, dict, list] | None:
    """`obj:M(args)` -> (M, obj node, args)."""
    if not e or e.get("type") != "AstExprCall" or not e.get("self"):
        return None
    fn = e.get("func") or {}
    if fn.get("type") != "AstExprIndexName":
        return None
    return str(fn.get("index")), fn.get("expr") or {}, list(e.get("args") or [])


def _calls_in(e: dict | None) -> list[tuple[str, dict, list]]:
    """The method calls an expression is made of: `a:F() or b:G()`, `(a:F())`, `a:F() :: T`."""
    if not e:
        return []
    t = e.get("type")
    if t in ("AstExprGroup", "AstExprTypeAssertion"):
        return _calls_in(e.get("expr"))
    if t == "AstExprBinary" and e.get("op") in ("Or", "And"):
        return _calls_in(e.get("left")) + _calls_in(e.get("right"))
    mc = _method_call(e)
    return [mc] if mc else []


def _unwrap_iter(e: dict | None) -> dict | None:
    """ipairs(x) / pairs(x) -> x."""
    while e and e.get("type") == "AstExprCall" and (e.get("func") or {}).get("type") == "AstExprGlobal" \
            and e["func"].get("global") in ("ipairs", "pairs") and e.get("args"):
        e = e["args"][0]
    return e


def _root_local(n: dict | None) -> dict | None:
    """The local at the base of `a`, `a.b.c` or `a[k]`."""
    while n and n.get("type") in ("AstExprIndexName", "AstExprIndexExpr", "AstExprGroup", "AstExprTypeAssertion"):
        n = n.get("expr")
    return n if n and n.get("type") == "AstExprLocal" else None


def _last_name(n: dict | None) -> str | None:
    """`player.Backpack` / `player:WaitForChild("Backpack")` / `p:FindFirstChildOfClass("Backpack")` -> Backpack."""
    while n and n.get("type") in ("AstExprGroup", "AstExprTypeAssertion"):
        n = n.get("expr")
    if not n:
        return None
    if n.get("type") == "AstExprIndexName":
        return str(n.get("index"))
    mc = _method_call(n)
    if mc and mc[2] and mc[2][0].get("type") == "AstExprConstantString":
        return str(mc[2][0].get("value"))
    return None


def _meet(a: set, b: set) -> bool:
    """Two value sets name the same object: an equal value, a created object seen from a longer call chain, or a
    service and a lookup of the same name."""
    for x in a:
        for y in b:
            if x == y:
                return True
            if x[0] == "new" and y[0] == "new" and (x[1][-len(y[1]):] == y[1] or y[1][-len(x[1]):] == x[1]):
                return True
            if {x[0], y[0]} == {"svc", "named"} and x[1] == y[1]:
                return True
    return False


LABEL_ORDER = ("ActionText", "Text", "ObjectText")


def _label(labels: set[tuple[str, str]]) -> str:
    """The text the player reads on it: ActionText for a prompt, Text for a button."""
    good = [(LABEL_ORDER.index(p) if p in LABEL_ORDER else 9, x) for p, x in labels if x and not x.isspace()]
    return sorted(good)[0][1] if good else ""


def _describe(cls: str, names: set[str], labels: set[tuple[str, str]]) -> str:
    name = sorted(n for n in names if n and n != cls)
    label = _label(labels)
    out = cls + (f" {_q(name[0])}" if name else "")
    return out + (f" ({_q(label)})" if label else "")


def load_game(game_dir: Path, *, exe: str | None = None) -> tuple[Game, list[dict]]:
    """Parse every game file (kit modules only when the game names them) -> (Game, parse errors)."""
    game_dir = Path(game_dir)
    paths = sorted(p for p in game_dir.rglob("*.luau") if not _skipped(p.relative_to(game_dir).as_posix()))
    rels = {p: p.relative_to(game_dir).as_posix() for p in paths}
    game_text = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in paths
                          if not rels[p].startswith(KIT_DIR))
    live = [p for p in paths if not rels[p].startswith(KIT_DIR)
            or re.search(rf"\b{re.escape(_stem(rels[p]))}\b", game_text)]
    exe = exe or luau_ast()
    with ThreadPoolExecutor(max_workers=8) as pool:
        parsed = list(pool.map(lambda p: parse_file(p, exe), live))
    files, errors = {}, []
    for p, (root, err) in zip(live, parsed):
        rel = rels[p]
        if root is None:
            errors.append({"file": rel, "error": err})
            continue
        files[rel] = _File(rel, root, rel.startswith(KIT_DIR))
    return Game(files), errors


def audit(game_dir: Path | str) -> dict:
    """-> {ok, findings[{id, kind, severity, file, line, object, detail, fix, kit}], stats, errors, skipped?}.
    ok is None (unknown) when luau-ast is missing; else True when no finding is high or medium."""
    game_dir = Path(game_dir)
    if not game_dir.is_dir():
        return {"ok": None, "skipped": f"no game folder at {game_dir}", "findings": [], "stats": {}, "errors": []}
    exe = luau_ast()
    if not exe:
        return {"ok": None, "skipped": "luau-ast not on PATH (brew install luau)", "findings": [], "stats": {},
                "errors": []}
    old = sys.getrecursionlimit()
    sys.setrecursionlimit(max(old, 20000))
    try:
        game, errors = load_game(game_dir, exe=exe)
        findings, stats = _run(game)
    finally:
        sys.setrecursionlimit(old)
    findings.sort(key=lambda x: (("high", "medium", "low").index(x["severity"]), x["file"], x["line"]))
    return {"ok": not any(x["severity"] in GATE_SEVERITIES for x in findings), "findings": findings,
            "stats": stats, "errors": errors}


def _signals(game: Game, a: _Audit) -> dict:
    """Every connection, callback and send in the game, with what its target can be: handled object chains,
    handled names and generic handlers per family, PromptTriggered handlers, remote/bindable sends and receives."""
    out: dict = {"handled": {fam: [] for fam in HANDLER_EVENTS}, "named": {fam: set() for fam in HANDLER_EVENTS},
                 "generic": {fam: [] for fam in HANDLER_EVENTS}, "global_prompt": [], "sends": [], "receives": [],
                 "tools": 0}
    exported: dict[str, list[tuple[dict, _File]]] = {}  # M.Done = bindable.Event: connections to .Done listen
    for f in game.files.values():
        for target, value in f.props:
            prop = target.get("index") if target.get("type") == "AstExprIndexName" else None
            if prop in CALLBACKS:
                out["receives"].append({"sig": prop, "vals": game.ev(target.get("expr"), f, None), "file": f,
                                        "node": target})
            v = value
            while v.get("type") in ("AstExprGroup", "AstExprTypeAssertion"):
                v = v.get("expr") or {}
            if prop and v.get("type") == "AstExprIndexName" and v.get("index") == "Event":
                exported.setdefault(str(prop), []).append((v.get("expr"), f))
        for call, _ in f.calls:
            fn = call.get("func") or {}
            if fn.get("type") != "AstExprIndexName" or not call.get("self"):
                continue
            m, sig = str(fn.get("index")), fn.get("expr") or {}
            if m in SENDS:
                out["sends"].append({"m": m, "vals": game.ev(sig, f, None), "file": f, "node": call})
            if m not in CONNECT or sig.get("type") != "AstExprIndexName":
                continue
            ev_name = str(sig.get("index"))
            vals = game.ev(sig.get("expr"), f, None)
            fam = EVENT_FAMILY.get(ev_name)
            if fam == BUTTON and ev_name in TOOL_EVENTS and a.is_tool(sig.get("expr"), f):
                out["tools"] += 1  # Tool.Activated: not a button handler
                fam = None
            if fam:
                out["handled"][fam] += a._chains(vals)
                out["named"][fam] |= {v[1] for v in vals if v[0] == "named"}
                if UNK in vals or any(v[0] == "cls" and v[1] in FAMILY_CLASSES[fam] for v in vals):
                    out["generic"][fam].append({"at": f"{f.rel}:{_line(call)}", "scope": a.scope(sig.get("expr"), f)})
            if ev_name in ("PromptTriggered", "PromptTriggerEnded") and ("svc", "ProximityPromptService") in vals:
                covers = _prompt_filter((call.get("args") or [None])[0], f, game)
                if covers is True:  # every prompt reaches it: a generic handler, whatever it does with them
                    out["generic"][PROMPT].append({"at": f"{f.rel}:{_line(call)}", "scope": ("all",)})
                else:
                    out["global_prompt"].append(covers)
            if ev_name in LISTENS:
                out["receives"].append({"sig": ev_name, "vals": vals, "file": f, "node": call})
        for node in _dot_methods(f):  # pcall(remote.InvokeServer, remote, ...): the method as a value
            out["sends"].append({"m": node.get("index"), "vals": game.ev(node.get("expr"), f, None), "file": f,
                                 "node": node})
    for f in game.files.values():  # connections to exported bindable events, now that every export is known
        for call, _ in f.calls:
            fn = call.get("func") or {}
            sig = fn.get("expr") or {}
            if fn.get("type") == "AstExprIndexName" and str(fn.get("index")) in CONNECT and \
                    sig.get("type") == "AstExprIndexName" and str(sig.get("index")) in exported:
                for src, sf in exported[str(sig.get("index"))]:
                    out["receives"].append({"sig": "Event", "vals": game.ev(src, sf, None), "file": f, "node": call})
    return out


def _run(game: Game) -> tuple[list[dict], dict]:
    a = _Audit(game)
    a.collect_facts()
    sig = _signals(game, a)
    findings: list[dict] = []
    stats: dict = {"files": len(game.files), "objects": 0, "handled": 0, "generic": 0, "unknown": 0, "senders": 0,
                   "receivers": 0, "generic_at": {}, "suppressed": [], "tool_connections": sig["tools"]}
    bindable_names: set[str] = set()
    seen_chains: set[tuple] = set()
    for f in game.files.values():
        for call, _ in f.calls:
            vals = game.ev(call, f, None)
            mine = [v for v in vals if v[0] == "new" and v[1][0] == game.site_key(call, f)]
            for _, chain, cls in mine:
                if cls in BINDABLE_CLASSES:
                    bindable_names |= a.chain_names(chain)
                fam = FAMILY.get(cls)
                if not fam or chain in seen_chains:
                    continue
                seen_chains.add(chain)
                if fam == BUTTON and a._of({c: {True} for c in a.inert}, chain):
                    stats["inert"] = stats.get("inert", 0) + 1  # zero size: nothing to click
                    continue
                stats["objects"] += 1
                cnames, clabels = a.call_names(call, f, cls) if len(chain) > 1 else (set(), set())
                names = a._of(a.names, chain) | cnames
                labels = a._of(a.labels, chain) | clabels
                how = _is_handled(chain, cls, fam, names, sig, a, f.rel)
                if how == "matched":
                    stats["handled"] += 1
                elif how:
                    stats["generic"] += 1
                    stats["generic_at"][how] = stats["generic_at"].get(how, 0) + 1
                elif not a.ctx_safe(call, f):
                    stats["unknown"] += 1
                else:
                    findings.append(_object_finding(fam, cls, call, f, names, labels))
    findings += _comm_findings(sig["sends"], sig["receives"], bindable_names, a, stats)
    seen: dict[str, int] = {}
    for x in sorted(findings, key=lambda x: (x["file"], x["line"], x["kind"])):
        x["severity"] = SEVERITY[x["kind"]]
        # kind + file + object, not the line: an edit that shifts lines keeps the id (rejections, still_dead)
        base = f"{x['kind']}:{x['file']}:{x['object']}"
        seen[base] = seen.get(base, 0) + 1
        x["id"] = base if seen[base] == 1 else f"{base}#{seen[base]}"
    return findings, stats


def _dot_methods(f: _File) -> list[dict]:
    """`remote.InvokeServer` used as a value (pcall(remote.InvokeServer, remote, ...)), not called."""
    out = []
    for call, _ in f.calls:
        fn = call.get("func") or {}
        if fn.get("type") == "AstExprGlobal" and fn.get("global") in ("pcall", "xpcall"):
            first = (call.get("args") or [None])[0] or {}
            if first.get("type") == "AstExprIndexName" and first.get("index") in SENDS \
                    and first.get("index") not in ("Fire", "Invoke"):
                out.append(first)
    return out


def _is_handled(chain: tuple, cls: str, fam: str, names: set[str], sig: dict, a: _Audit, cfile: str) -> str:
    """"matched": a connection on this object (or on what the helper that made it returned), on its name, or
    (prompts) a PromptTriggered handler that tests for something it carries. "<file:line>": only a generic handler
    of its family reaches it (its container, tag or file). "": nothing."""
    if any(len(h) <= len(chain) and chain[-len(h):] == h for h in sig["handled"][fam]):
        return "matched"
    if (names or {cls}) & sig["named"][fam]:
        return "matched"
    if fam == PROMPT:
        ident = names | a._of(a.ident, chain) | {cls}
        if any(covers & ident for covers in sig["global_prompt"]):
            return "matched"
    return next((g["at"] for g in sig["generic"][fam] if a.within(chain, g["scope"], cfile)), "")


def _prompt_filter(handler: dict | None, f: _File, game: Game) -> bool | set[str]:
    """A ProximityPromptService.PromptTriggered handler: True when it handles every prompt (no string tests on
    the prompt), else the strings it tests (names, attributes, tags, action texts)."""
    node = handler or {}
    if node.get("type") == "AstExprLocal":
        fk = f.local_funcs.get(f.lkey(node["local"]))
        node = (f.funcs.get(fk) or {}).get("node") or {}
    if node.get("type") != "AstExprFunction":
        return True
    found: set[str] = set()
    stack: list[Any] = [node.get("body")]
    while stack:
        n = stack.pop()
        if isinstance(n, list):
            stack.extend(n)
            continue
        if not isinstance(n, dict):
            continue
        t = n.get("type")
        if t == "AstExprBinary" and n.get("op") in ("CompareEq", "CompareNe"):
            for side in (n.get("left"), n.get("right")):
                if (side or {}).get("type") == "AstExprConstantString":
                    found.add(str(side.get("value")))
        if t == "AstExprCall":
            fn = n.get("func") or {}
            if fn.get("type") == "AstExprIndexName" and fn.get("index") in (
                    "GetAttribute", "HasTag", "FindFirstAncestor", "IsDescendantOf", "FindFirstChild"):
                for arg in n.get("args") or []:
                    if arg.get("type") == "AstExprConstantString":
                        found.add(str(arg.get("value")))
        if t == "AstExprIndexExpr":
            return True  # a dispatch table keyed by the prompt: it may handle any prompt
        for k, v in n.items():
            if k not in ("type", "location") and isinstance(v, (dict, list)):
                stack.append(v)
    return found or True


def _object_finding(fam: str, cls: str, call: dict, f: _File, names: set[str], labels: set) -> dict:
    what = _describe(cls, names, labels)
    label = _label(labels)
    if fam == PROMPT:
        detail = (f"{what} is created here, but nothing connects its Triggered and no ProximityPromptService."
                  "PromptTriggered handler covers it: the player sees the prompt, presses E, and nothing happens")
        fix = (f"connect its Triggered on the server to what {_q(label) if label else 'the prompt'} promises "
               "(open the panel, start the ride, buy the item), or reuse a prompt that is already handled")
        kind = "prompt_no_handler"
    elif fam == CLICK:
        detail = f"{what} is created here, but nothing connects its MouseClick: clicking it does nothing"
        fix = "connect its MouseClick to what the clickable part promises"
        kind = "click_no_handler"
    else:
        detail = (f"{what} is created here, but nothing connects its Activated (or MouseButton1Click): pressing "
                  "it does nothing")
        fix = "connect its Activated to what the button says, or make it a TextLabel if it is only a label"
        kind = "button_no_handler"
    return {"kind": kind, "file": f.rel, "line": _line(call), "object": what, "detail": detail, "fix": fix,
            "kit": f.kit}


def _site_refs(site: dict, a: _Audit) -> tuple[set[str], set[tuple]]:
    vals = site["vals"]
    names = {v[1] for v in vals if v[0] == "named"}
    chains = set(a._chains(vals))
    for c in chains:
        names |= a.chain_names(c)
    return names, chains


def _comm_findings(sends: list[dict], receives: list[dict], bindable_names: set[str], a: _Audit,
                   stats: dict) -> list[dict]:
    out: list[dict] = []
    for f_methods, sig, fwd, rev in PAIRS:
        bindable = sig in ("Event", "OnInvoke")
        ss = [s for s in sends if s["m"] in f_methods]
        rr = [r for r in receives if r["sig"] == sig]
        if bindable:  # :Fire / :Invoke / .Event are generic names: only bindables we saw created count
            def is_bindable(site: dict) -> bool:
                names, chains = _site_refs(site, a)
                return bool(names & bindable_names) or any(
                    v[0] == "new" and v[2] in BINDABLE_CLASSES for v in site["vals"])
            ss = [s for s in ss if is_bindable(s)]
            rr = [r for r in rr if is_bindable(r)]
        stats["senders"] += len(ss)
        stats["receivers"] += len(rr)
        sref = [(s, *_site_refs(s, a)) for s in ss]
        rref = [(r, *_site_refs(r, a)) for r in rr]
        if not bindable:
            sref = [(s, n, set()) for s, n, _ in sref]
            rref = [(r, n, set()) for r, n, _ in rref]

        def unresolved(site: dict, n: set, c: set) -> bool:
            """No name and no identity, or one alternative unknown: it might be any remote."""
            return (not n and not c) or UNK in site["vals"]

        r_open = [x[0] for x in rref if unresolved(*x)]
        s_open = [x[0] for x in sref if unresolved(*x)]
        r_unresolved, s_unresolved = bool(r_open), bool(s_open)
        # a listener it cannot name may be any remote's: no "nothing listens" for these sends (and the reverse)
        for site in r_open[:3] if sref else []:
            stats["suppressed"].append({"at": f"{site['file'].rel}:{_line(site['node'])}", "site": sig,
                                        "off": fwd, "for": "/".join(f_methods)})
        for site in s_open[:3] if rref else []:
            stats["suppressed"].append({"at": f"{site['file'].rel}:{_line(site['node'])}", "site": site["m"],
                                        "off": rev, "for": sig})

        def meets(n1: set, c1: set, others: list) -> bool:
            return any((n1 & n2) or (c1 & c2) or any(x[-len(y):] == y or y[-len(x):] == x for x in c1 for y in c2)
                       for _, n2, c2 in others)

        if not r_unresolved:
            for s, n, c in sref:
                if not unresolved(s, n, c) and not meets(n, c, rref):
                    out.append(_comm_finding(fwd, s, n, sig, sending=True))
        if not s_unresolved:
            for r, n, c in rref:
                if not unresolved(r, n, c) and not meets(n, c, sref):
                    out.append(_comm_finding(rev, r, n, sig, sending=False, methods=f_methods))
    # one finding per (kind, name): the first site, with the others counted
    merged: dict[tuple, dict] = {}
    for x in out:
        key = (x["kind"], x["object"])
        if key in merged:
            merged[key]["also"] = merged[key].get("also", 0) + 1
        else:
            merged[key] = x
    for x in merged.values():
        if x.get("also"):
            x["detail"] += f" (and {x['also']} more place(s))"
    return list(merged.values())


KIND_CLASS = {"OnServerEvent": "RemoteEvent", "OnClientEvent": "RemoteEvent", "OnServerInvoke": "RemoteFunction",
              "OnClientInvoke": "RemoteFunction", "Event": "BindableEvent", "OnInvoke": "BindableFunction"}


def _comm_finding(kind: str, site: dict, names: set[str], sig: str, *, sending: bool,
                  methods: tuple = ()) -> dict:
    f, node = site["file"], site["node"]
    cls = KIND_CLASS[sig]
    name = sorted(names)[0] if names else ""
    what = cls + (f" {_q(name)}" if name else "")
    if sending:
        m = site["m"]
        detail = {"remote_no_listener": f"{what} is sent with {m} here, but nothing connects its {sig}: the message "
                                        "is dropped and whatever the player did has no effect",
                  "remote_no_answer": f"{what} is invoked with {m} here, but nothing sets its {sig}: the call never "
                                      "returns",
                  "bindable_no_listener": f"{what} is fired here, but nothing connects its Event",
                  "bindable_no_answer": f"{what} is invoked here, but nothing sets its OnInvoke: the call never "
                                        "returns"}[kind]
        fix = f"add the {sig} handler on the other side, or remove the dead {m} call and the feature that needs it"
    else:
        sent = "/".join(methods)
        detail = (f"{what} has a {sig} handler here, but nothing in the game calls {sent} on it: the feature behind "
                  "it can never run (a missing button or client half?)")
        fix = f"wire the {sent} call where the player asks for this, or delete the dead handler"
    return {"kind": kind, "file": f.rel, "line": _line(node), "object": what, "detail": detail, "fix": fix,
            "kit": f.kit}


# ---------------------------------------------------------------------------------------------- outputs


def _short(at: str) -> str:
    return at.rsplit("/", 1)[-1]


def coverage(st: dict) -> str:
    """'83 prompts/buttons/detectors: 60 matched, 20 only by a generic handler (A.luau:12), 3 not followed; 80
    sends checked; remote checks suppressed by B.luau:531 (OnClientEvent)': what the audit really checked."""
    objects = int(st.get("objects") or 0)
    out = f"{objects} prompts/buttons/detectors"
    parts = [f"{st.get('handled', 0)} matched to a handler"]
    if st.get("generic"):
        where = sorted((st.get("generic_at") or {}).items(), key=lambda kv: -kv[1])
        parts.append(f"{st['generic']} only by a generic handler (" + ", ".join(_short(k) for k, _ in where[:3])
                     + (", ..." if len(where) > 3 else "") + ")")
    if st.get("unknown"):
        parts.append(f"{st['unknown']} not followed")
    out += (": " + ", ".join(parts)) if objects else ""
    out += f"; {st.get('senders', 0)} sends checked"
    sup = st.get("suppressed") or []
    if sup:
        out += "; remote checks suppressed by " + ", ".join(
            f"{_short(x['at'])} ({x['site']})" for x in sup[:3]) + (", ..." if len(sup) > 3 else "")
    return out


def summary(res: dict, limit: int = 4) -> str:
    """One line for `forge done`: '2 dead: Shop.luau:196 ProximityPrompt "ChangingRoomPrompt" ...; ...'."""
    if res.get("ok") is None:
        return "unknown: " + str(res.get("skipped") or "not audited")
    bad = [x for x in res.get("findings") or [] if x["severity"] in GATE_SEVERITIES]
    st = res.get("stats") or {}
    if not bad:
        low = len(res.get("findings") or [])
        return f"no dead interactions ({coverage(st)})" + (f"; {low} low" if low else "")
    parts = [f"{x['file'].rsplit('/', 1)[-1]}:{x['line']} {x['object']} ({x['kind']})" for x in bad[:limit]]
    return f"{len(bad)} dead: " + "; ".join(parts) + ("; ..." if len(bad) > limit else "") + f" ({coverage(st)})"


def render(res: dict) -> str:
    if res.get("ok") is None:
        return "interactions: " + summary(res)
    lines = [f"interactions: {'OK' if res['ok'] else 'DEAD INTERACTIONS'}", f"  checked: {coverage(res.get('stats') or {})}"]
    for x in (res.get("stats") or {}).get("suppressed") or []:
        lines.append(f"  [suppressed] {x['at']}: {x['site']} on a remote the audit cannot name, so no {x['off']} is "
                     f"reported for {x['for']}")
    for x in res.get("findings") or []:
        lines.append(f"  [{x['severity']}] {x['file']}:{x['line']}  {x['kind']}{'  (kit)' if x.get('kit') else ''}")
        lines.append(f"      {x['detail']}")
        lines.append(f"      fix: {x['fix']}")
    for e in res.get("errors") or []:
        lines.append(f"  [parse] {e['file']}: {e['error']}")
    return "\n".join(lines)


def _gating(res: dict) -> list[dict]:
    return [x for x in res.get("findings") or [] if x["severity"] in GATE_SEVERITIES]


def ref_of(x: dict) -> str:
    """The evidence ref of a finding: kind + file + object (+ #n), never the line, so a developer's rejection of
    it survives an edit that shifts lines."""
    obj = re.sub(r"[^A-Za-z0-9]+", "-", str(x.get("object") or "")).strip("-")[:60] or "object"
    dup = str(x.get("id") or "").rpartition("#")[2] if "#" in str(x.get("id") or "") else ""
    return f"dead:{x['file']}:{x['kind']}:{obj}" + (f"#{dup}" if dup.isdigit() else "")


def as_anomalies(res: dict) -> list[dict]:
    """High/medium findings in the auditor's anomaly shape, for the fix loop: `proof` (no reproducer needed) and
    `finding` (improve.fix_code re-audits after each attempt: still_dead)."""
    bad = _gating(res)
    out = []
    for x in bad:
        same = sum(1 for y in bad if y["kind"] == x["kind"] and y["file"] == x["file"] and y["object"] == x["object"])
        in_file = sum(1 for y in bad if y["kind"] == x["kind"] and y["file"] == x["file"])
        out.append({"kind": "dead_interaction", "system": "interactions", "severity": x["severity"],
                    "title": f"[interactions] {x['object']} at {x['file']}:{x['line']} does nothing ({x['kind']})"[:300],
                    "observed": x["detail"], "expected": x["fix"],
                    "proof": f"static interaction audit (forge interactions): {x['file']}:{x['line']}: {x['detail']}",
                    "finding": {"kind": x["kind"], "file": x["file"], "object": x["object"], "count": same,
                                "in_file": in_file},
                    "ref": ref_of(x),
                    **({} if x.get("kit") else {"path": x["file"]})})
    return out


def still_dead(game_dir: Path | str, finding: dict) -> str:
    """'' when a fix cleared the finding: no finding of its kind, file and object is left (when several had the
    same object text, fewer of them are left). Else why not, for the fixer's retry. A fix that only renames the
    object (its kind still has as many findings in its file as before) is not a fix either."""
    res = audit(game_dir)
    if res.get("ok") is None:
        return ""  # cannot audit (no luau-ast): not a reason to reject a fix
    left = [x for x in _gating(res) if x["kind"] == finding.get("kind") and x["file"] == finding.get("file")]
    exact = [x for x in left if x["object"] == finding.get("object")] if finding.get("object") else left
    renamed = bool(finding.get("in_file")) and not exact and len(left) >= int(finding["in_file"])
    if len(exact) < int(finding.get("count") or 1) and not renamed:
        return ""
    shown = exact or left
    return ("The static interaction audit still finds it after your fix: "
            + "; ".join(f"{x['file']}:{x['line']} {x['detail']}" for x in shown[:3])
            + ". Connect the handler on the object itself (or reuse one that is handled).")
