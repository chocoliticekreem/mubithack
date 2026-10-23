"""Local companion for the native MuMake Studio plugin.

Run: python -m mubit_tester.studio_service
Only the paired local plugin can submit jobs. Jobs bind to an exact Studio
instance through an editor-local marker; no fallback to the first open place.
"""
from __future__ import annotations

import argparse
import asyncio
import hmac
import json
import os
import secrets
import signal
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from forge.config import load_settings
from forge.studio import Studio, extract_json
from mubit_tester.harness import Harness, _long_bracket
from mubit_tester.scenario import list_scenarios, load_scenario, run_scenario
from mubit_tester.studio_presenter import check_choices, present_job

PROTOCOL = 1
DEFAULT_PORT = 34874
TERMINAL = {"passed", "failed", "skipped", "cancelled", "interrupted"}
OPERATIONS = {"install_harness", "scenario", "playtest", "explore", "inspect", "suggest_fix", "correct"}
MARKER_CODE = '''local s=game:GetService("ServerScriptService")
local p=game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
return game:GetService("HttpService"):JSONEncode({
marker=game:GetService("CoreGui"):GetAttribute("MubitTesterSession"),
name=game.Name,placeId=game.PlaceId,
harnessReady=s:FindFirstChild("ForgeTest")~=nil and s:FindFirstChild("ForgeProbe")~=nil
and game:GetService("ReplicatedStorage"):FindFirstChild("ForgeTelemetry")~=nil
and p~=nil and p:FindFirstChild("ForgeTestAgent")~=nil})'''


def runtime_files(root: Path) -> list[dict]:
    paths = [
        ("ServerScriptService", "ForgeProbe", root / "game/ServerScriptService/ForgeProbe.server.luau", "Script"),
        ("ReplicatedStorage", "ForgeTelemetry", root / "game/ReplicatedStorage/ForgeTelemetry.luau", "ModuleScript"),
        ("ServerScriptService", "ForgeTest", root / "mubit-tester/roblox/ForgeTest.server.luau", "Script"),
        ("StarterPlayerScripts", "ForgeTestAgent", root / "mubit-tester/roblox/ForgeTestAgent.client.luau", "LocalScript"),
    ]
    return [{"service": service, "name": name, "source": path.read_text(), "class": cls}
            for service, name, path, cls in paths]


def install_code(root: Path) -> str:
    payload = json.dumps(runtime_files(root), ensure_ascii=False)
    return f'''
local files=game:GetService("HttpService"):JSONDecode({_long_bracket(payload)})
local editor=game:GetService("ScriptEditorService")
local history=game:GetService("ChangeHistoryService")
local targets={{}}
for _,f in files do
    local parent=f.service=="StarterPlayerScripts"
        and game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts") or game:GetService(f.service)
    local target=parent:FindFirstChild(f.name)
    if target and target.ClassName~=f.class then error("Conflicting instance: "..f.name) end
    table.insert(targets,{{file=f,parent=parent,target=target}})
end
-- ExecuteLuau already wraps changes in the Assistant plugin's undo recording.
local inheritedRecording=history:IsRecordingInProgress()
local recording
if not inheritedRecording then
    recording=history:TryBeginRecording("MubitTesterHarness", "Set up MuMake")
    if not recording then error("Undo recording unavailable; finish the current Studio operation and retry") end
end
local ok,err=pcall(function()
    for _,item in targets do
        local f,parent,target=item.file,item.parent,item.target
        if not target then target=Instance.new(f.class) target.Name=f.name target.Parent=parent end
        editor:UpdateSourceAsync(target,function() return f.source end)
        target:SetAttribute("MubitTesterManaged",true)
    end
end)
if recording then
    history:FinishRecording(recording,ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
end
if not ok then error(err) end
return "Installed 4 Studio-only test runtime scripts"
'''


class ProgressHarness(Harness):
    def __init__(self, studio, emit):
        super().__init__(studio)
        self.emit = emit

    async def call(self, cmd: str, **args):
        if cmd not in {"players", "events", "counters", "query", "observe", "ping"}:
            self.emit(f"{cmd}: {args.get('action', '')}".strip())
        return await super().call(cmd, **args)


class Companion:
    def __init__(self, settings=None, studio_factory=Studio, store: Path | None = None):
        self.settings = settings or load_settings()
        self.studio_factory = studio_factory
        self.store = store or self.settings.runs_dir / "studio-plugin"
        self.store.mkdir(parents=True, exist_ok=True)
        self.jobs: dict[str, dict] = {}
        self.sessions: dict[str, dict] = {}
        self.task: asyncio.Task | None = None
        self.active: str | None = None
        self.bind_lock = asyncio.Lock()
        self.last_seen: dict[str, float] = {}
        for path in sorted(self.store.glob("job-*.json"))[-100:]:
            try:
                job = json.loads(path.read_text())
                if job["state"] not in TERMINAL:
                    job.update(state="interrupted", ended=time.time(),
                               error="Companion restarted; this job was not replayed.")
                self.jobs[job["id"]] = job
            except (OSError, ValueError, KeyError):
                continue

    def save(self, job: dict):
        path = self.store / f"job-{job['id']}.json"
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(job, ensure_ascii=False, default=str))
        temp.replace(path)

    def emit(self, job: dict, message: str):
        if job["state"] in TERMINAL:
            return
        job["events"].append({"n": len(job["events"]) + 1, "time": time.time(), "message": message[:1200]})
        job["events"] = job["events"][-200:]
        self.save(job)

    async def bind(self, marker: str):
        if not isinstance(marker, str) or not 8 <= len(marker) <= 100:
            raise ValueError("Invalid Studio session marker")
        async with self.bind_lock:
            async with self.studio_factory(self.settings, call_timeout=30) as studio:
                for _ in range(12):
                    for item in await studio.list_studios():
                        studio.studio_id = item["id"]
                        try:
                            info = extract_json(await studio.execute_luau(MARKER_CODE))
                        except Exception:
                            continue
                        if isinstance(info, dict) and info.get("marker") == marker:
                            session = {"studio_id": item["id"], "name": info["name"],
                                       "place_id": info.get("placeId", 0), "marker": marker,
                                       "harness_ready": bool(info.get("harnessReady"))}
                            self.sessions[marker] = session
                            return session
                    await asyncio.sleep(1)
        raise ValueError("Studio did not connect. Enable Studio as MCP server in Assistant settings, then reconnect.")

    def snapshot(self, marker: str | None = None):
        if marker:
            self.last_seen[marker] = time.monotonic()
        session = self.sessions.get(marker or "")
        jobs = sorted(self.jobs.values(), key=lambda j: j["created"], reverse=True)
        if session:
            jobs = [j for j in jobs if j["studio_id"] == session["studio_id"]]
        else:
            jobs = []
        def view(job):
            return {**job, "presentation": present_job(job)} if job else None
        scenarios = list_scenarios(self.settings.repo_root)
        return {"protocol": PROTOCOL, "has_mubit_key": bool(self.settings.mubit_api_key),
                "model": self.settings.model, "session": session,
                "busy": self.active is not None,
                "active": view(self.jobs.get(self.active)) if self.active and session
                and self.jobs[self.active]["studio_id"] == session["studio_id"] else None,
                "history": [view(job) for job in jobs[:12]], "scenarios": scenarios,
                "check_choices": check_choices(scenarios)}

    def submit(self, payload: dict):
        marker = payload.get("session")
        session = self.sessions.get(marker or "")
        if not session:
            raise ValueError("Connect this Studio session first")
        if self.active:
            raise ValueError("A native plugin job is already running. Stop or finish it first.")
        operation = payload.get("operation")
        if operation not in OPERATIONS:
            raise ValueError("Unsupported operation")
        # Roblox encodes an empty Lua table as [] rather than {}.
        if payload.get("args") and not isinstance(payload["args"], dict):
            raise ValueError("Expected operation arguments")
        args = dict(payload.get("args") or {})
        if operation in {"playtest", "explore", "suggest_fix", "correct"} and not self.settings.mubit_api_key:
            raise ValueError("MUBIT_API_KEY is missing in the companion's .env. Scripted scenarios work without it.")
        if operation == "scenario":
            names = {s["file"] for s in list_scenarios(self.settings.repo_root)}
            if args.get("scenario", "smoke.json") not in names:
                raise ValueError("Choose a bundled scenario")
        if operation in {"playtest", "explore"}:
            args["steps"] = max(1, min(20, int(args.get("steps", 8))))
            if operation == "playtest" and not str(args.get("goal", "")).strip():
                raise ValueError("Describe a playtest goal")
        if operation in {"suggest_fix", "correct"}:
            run_id = str(args.get("run_id", ""))
            if not run_id or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in run_id):
                raise ValueError("Select a saved playtest report")
        job = {"id": uuid.uuid4().hex, "operation": operation, "args": args,
               "studio_id": session["studio_id"], "studio_name": session["name"],
               "marker": marker, "created": time.time(), "state": "queued", "events": [], "result": None}
        self.jobs[job["id"]] = job
        self.active = job["id"]
        self.save(job)
        self.task = asyncio.create_task(self.run(job))
        self.last_seen[marker] = time.monotonic()
        self.task.add_done_callback(lambda task: self.finish_cancelled(task, job))
        return job

    def finish_cancelled(self, task, job):
        # Cancellation can happen before run() gets its first event-loop turn.
        if task.cancelled() and self.active == job["id"]:
            job.update(state="cancelled", ended=time.time())
            self.save(job)
            self.active = self.task = None

    async def watch_lease(self):
        while True:
            await asyncio.sleep(2)
            if self.active:
                job = self.jobs[self.active]
                if time.monotonic() - self.last_seen.get(job["marker"], 0) > 45:
                    await self.stop(job["marker"])

    async def stop(self, marker: str):
        session = self.sessions.get(marker)
        if not self.active or not session:
            raise ValueError("No active job for this Studio session")
        job = self.jobs[self.active]
        if job["studio_id"] != session["studio_id"]:
            raise ValueError("This job belongs to another Studio session")
        if job["state"] != "cancelling":
            job["state"] = "cancelling"
            self.emit(job, "Stopping new actions and returning the owned playtest to Edit.")
            self.task.cancel()
        return job

    async def run(self, job: dict):
        owned_play = False
        try:
            job["state"] = "running"
            self.emit(job, "Connecting to the bound Studio session.")
            async with self.studio_factory(self.settings, studio_id=job["studio_id"], call_timeout=45) as studio:
                # The proxy may need a moment to reattach, but never switch to another instance.
                for attempt in range(12):
                    if any(s["id"] == job["studio_id"] for s in await studio.list_studios()):
                        break
                    if attempt == 11:
                        raise ValueError("The bound Studio session is no longer connected. Reconnect the panel.")
                    await asyncio.sleep(1)
                operation, args = job["operation"], job["args"]
                state = await studio.state()
                identity = {}
                if not state.get("playing"):
                    identity = extract_json(await studio.execute_luau(MARKER_CODE))
                    if not isinstance(identity, dict) or identity.get("marker") != job["marker"]:
                        raise ValueError("Studio identity changed; reconnect before running another job.")
                if operation in {"suggest_fix", "correct"}:
                    from mubit_tester.ai import correct_step, suggest_fix
                    self.emit(job, "Sending the report and request through Mubit.")
                    if operation == "suggest_fix":
                        result = await suggest_fix(self.settings, args["run_id"], int(args.get("bug", 0)))
                    else:
                        result = await correct_step(self.settings, args["run_id"], int(args.get("step", 1)),
                                                    str(args.get("note", "")), args.get("player") or None)
                    job["result"] = result
                elif operation == "inspect":
                    if not state.get("playing"):
                        raise ValueError("Start a playtest to read live players and errors.")
                    job["result"] = {"probe": await studio.probe_report(),
                                     "players": await Harness(studio).players()}
                else:
                    if state.get("playing"):
                        raise ValueError("A playtest is already running. Stop it in Studio first; the plugin will not take it over.")
                    if operation == "install_harness":
                        if identity.get("placeId"):
                            raise ValueError("Set up testing in a local place. Shared published places require the repository's normal sync workflow.")
                        self.emit(job, "Installing only the four test runtime scripts; other game scripts are preserved.")
                        job["result"] = {"summary": await studio.execute_luau(install_code(self.settings.repo_root))}
                        if job["marker"] in self.sessions:
                            self.sessions[job["marker"]]["harness_ready"] = True
                    else:
                        self.emit(job, "Starting a solo playtest.")
                        owned_play = True
                        try:
                            await studio.play()
                            harness = ProgressHarness(studio, lambda m: self.emit(job, m))
                            await harness.ensure_ready()
                            players = await harness.players()
                            if not players:
                                raise ValueError("No player spawned in the test.")
                            self.emit(job, f"{len(players)} player(s) ready; executing {operation}.")
                            if operation == "scenario":
                                result = await run_scenario(harness, load_scenario(str(self.settings.repo_root / "mubit-tester/scenarios" / args.get("scenario", "smoke.json")),
                                                                                  self.settings.repo_root))
                                result["probe"] = await studio.probe_report()
                                self.emit(job, "Scenario finished; captured runtime errors.")
                            else:
                                from mubit_tester.ai import multi_playtest, explore
                                self.emit(job, f"AI decisions use Mubit, at most {args['steps']} ticks plus the judge.")
                                if operation == "playtest":
                                    result = await multi_playtest(self.settings, args["goal"], players=1,
                                                                  steps=args["steps"], harness=harness)
                                else:
                                    result = await explore(self.settings, minutes=1, players=1,
                                                           max_ticks=args["steps"], harness=harness)
                            job["result"] = result
                        finally:
                            self.emit(job, "Stopping the owned playtest.")
                            await studio.stop()
                            owned_play = False
                if job["state"] != "cancelling":
                    result = job["result"] or {}
                    probe = result.get("probe") or {}
                    if result.get("skipped") or result.get("passed") is None and "passed" in result:
                        job["state"] = "skipped"
                    elif (result.get("passed") is False
                          or (operation in {"playtest", "explore"} and result.get("goal_met") is not True)
                          or result.get("bugs") or result.get("errors") or probe.get("errors")):
                        job["state"] = "failed"
                    else:
                        job["state"] = "passed"
        except asyncio.CancelledError:
            job["state"] = "cancelled"
        except Exception as error:
            job.update(state="failed", error=f"{type(error).__name__}: {error}"[:1800])
        finally:
            if owned_play:
                job.update(state="failed", error="Could not confirm owned playtest cleanup. Stop it in Studio before continuing.")
            job["ended"] = time.time()
            self.save(job)
            self.active = None
            self.task = None


def load_token(store: Path) -> str:
    store.mkdir(parents=True, exist_ok=True)
    path = store / "pairing-token"
    if not path.exists():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write(secrets.token_urlsafe(32))
    path.chmod(0o600)
    return path.read_text().strip()


def handler_for(service: Companion, loop, token: str):
    class Handler(BaseHTTPRequestHandler):
        server_version = "MuMake/1"
        def log_message(self, *_):
            pass

        def reply(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False, default=str).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def authorized(self):
            return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {token}")

        async def dispatch(self, path, payload):
            marker = self.headers.get("X-Mubit-Session", "")
            if self.command == "GET" and path in {"/health", "/state"}:
                return service.snapshot(marker)
            if self.command == "POST" and path == "/bind":
                return await service.bind(payload.get("marker", ""))
            if self.command == "POST" and path == "/jobs":
                payload["session"] = marker
                return service.submit(payload)
            if self.command == "POST" and path == "/cancel":
                return await service.stop(marker)
            raise LookupError("Unknown endpoint")

        def handle_request(self):
            if not self.authorized():
                return self.reply(401, {"error": "Pairing token required"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 0 or length > 16384:
                    return self.reply(413, {"error": "Request too large"})
                payload = json.loads(self.rfile.read(length)) if length else {}
                if not isinstance(payload, dict):
                    raise ValueError("Expected an object")
                path = urlsplit(self.path).path
                future = asyncio.run_coroutine_threadsafe(self.dispatch(path, payload), loop)
                try:
                    result = future.result(timeout=50)
                except TimeoutError:
                    future.cancel()
                    return self.reply(504, {"error": "Studio connection timed out"})
                self.reply(200, result)
            except LookupError as error:
                self.reply(404, {"error": str(error)})
            except (ValueError, TypeError) as error:
                self.reply(400, {"error": str(error)})
            except Exception as error:
                self.reply(500, {"error": str(error)[:1000]})

        do_GET = handle_request
        do_POST = handle_request
    return Handler


async def serve(port: int):
    service = Companion()
    token = load_token(service.store)
    loop = asyncio.get_running_loop()
    server = ThreadingHTTPServer(("127.0.0.1", port), handler_for(service, loop, token))
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    stopped = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopped.set)
    print(f"MuMake companion listening on 127.0.0.1:{port}", flush=True)
    watchdog = asyncio.create_task(service.watch_lease())
    try:
        await stopped.wait()
    finally:
        watchdog.cancel()
        await asyncio.gather(watchdog, return_exceptions=True)
        if service.task:
            service.task.cancel()
            await asyncio.gather(service.task, return_exceptions=True)
        await asyncio.to_thread(server.shutdown)
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()
    asyncio.run(serve(args.port))


if __name__ == "__main__":
    main()
