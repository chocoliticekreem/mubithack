"""LLM clients for forge. Every real call goes through the Mubit gateway.

Mubit groups calls into tasks by (system prompt, tools, output format, model), so each role's
system prompt is a fixed file in forge/prompts/<role>.md, loaded once and never modified per call.
Everything that varies goes in the user message.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Protocol

from forge.config import Settings

PROMPTS_DIR = Path(__file__).resolve().parent / "prompts"
# mubit-tester's roles (player, judge, explorer) keep their prompts in mubit-tester/prompts/.
PROMPT_DIRS = (PROMPTS_DIR, Path(__file__).resolve().parent.parent / "mubit-tester" / "prompts")
ROLES = ("designer", "coder", "fixer", "critic", "reflector", "player", "judge",
         "auditor", "verifier", "triage", "investigator", "patcher", "planner")

MAX_TRIES = 3  # total attempts for retryable gateway errors (429 / 503 / 529 overloaded)
RETRY_STATUSES = {429, 503, 529}
MAX_RETRY_WAIT_S = 60.0
JSON_REPAIRS = 2


class LLMError(RuntimeError):
    """An LLM call failed, or its reply could not be used."""


@dataclass
class LLMResult:
    text: str
    role: str
    request_id: str | None
    model: str
    latency_ms: int
    input_tokens: int | None
    output_tokens: int | None


class LLM(Protocol):
    def complete(
        self, role: str, user: str, *, session_id: str, max_tokens: int = 4096
    ) -> LLMResult: ...

    def complete_json(
        self,
        role: str,
        user: str,
        *,
        session_id: str,
        required: list[str],
        max_tokens: int = 4096,
    ) -> tuple[dict, LLMResult]: ...


# ---------------------------------------------------------------------------------------------
# prompts

_PROMPT_CACHE: dict[str, str] = {}
_PROMPT_LOCK = threading.Lock()


def load_prompt(role: str) -> str:
    """Return the fixed system prompt for a role (read once, cached for the process)."""
    if role not in ROLES:
        raise LLMError(f"unknown role {role!r}; expected one of {', '.join(ROLES)}")
    with _PROMPT_LOCK:
        if role not in _PROMPT_CACHE:
            path = next((d / f"{role}.md" for d in PROMPT_DIRS if (d / f"{role}.md").exists()),
                        PROMPTS_DIR / f"{role}.md")
            if not path.exists():
                raise LLMError(f"missing system prompt file {path}")
            _PROMPT_CACHE[role] = path.read_text(encoding="utf-8").strip()
        return _PROMPT_CACHE[role]


# ---------------------------------------------------------------------------------------------
# JSON extraction

_FENCE_RE = re.compile(r"```[ \t]*([A-Za-z0-9_+-]*)[ \t]*\n(.*?)```", re.DOTALL)


def extract_json_object(text: str) -> dict:
    """Return the first JSON object in text. Fenced ```json blocks are tried first.

    Raises ValueError with a short reason if none parses.
    """
    candidates: list[str] = []
    for m in _FENCE_RE.finditer(text):
        lang = m.group(1).lower()
        if lang in ("json", "", "jsonc"):
            candidates.append(m.group(2))
    candidates.append(text)

    decoder = json.JSONDecoder()
    last_err = "no JSON object found"
    for cand in candidates:
        start = cand.find("{")
        while start != -1:
            try:
                obj, _ = decoder.raw_decode(cand, start)
            except json.JSONDecodeError as e:
                last_err = f"invalid JSON: {e.msg} (line {e.lineno} col {e.colno})"
            else:
                if isinstance(obj, dict):
                    return obj
            start = cand.find("{", start + 1)
    raise ValueError(last_err)


def _check_required(obj: dict, required: list[str]) -> None:
    missing = [k for k in required if k not in obj]
    if missing:
        raise ValueError(f"JSON object is missing required keys: {', '.join(missing)}")


def _repair_message(user: str, error: str, previous: str) -> str:
    prev = previous if len(previous) <= 6000 else previous[:6000] + "\n...[truncated]"
    return (
        f"{user}\n\n"
        "## Your previous reply could not be used\n"
        f"Error: {error}\n\n"
        "Previous reply:\n"
        f"<<<\n{prev}\n>>>\n\n"
        "Reply again with ONLY the corrected JSON object (no prose, no code fence)."
    )


class _JSONMixin:
    """complete_json on top of complete(); shared by MubitLLM and FakeLLM."""

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult:
        raise NotImplementedError

    def complete_json(
        self,
        role: str,
        user: str,
        *,
        session_id: str,
        required: list[str],
        max_tokens: int = 4096,
    ) -> tuple[dict, LLMResult]:
        msg = user
        for attempt in range(JSON_REPAIRS + 1):
            res = self.complete(role, msg, session_id=session_id, max_tokens=max_tokens)
            try:
                obj = extract_json_object(res.text)
                _check_required(obj, required)
                return obj, res
            except ValueError as e:
                if attempt == JSON_REPAIRS:
                    raise LLMError(
                        f"{role}: no valid JSON after {JSON_REPAIRS} repairs: {e}"
                    ) from e
                msg = _repair_message(user, str(e), res.text)
        raise LLMError("unreachable")  # pragma: no cover


# ---------------------------------------------------------------------------------------------
# Mubit


def _header(headers, name: str) -> str | None:
    try:
        return headers.get(name)
    except Exception:  # noqa: BLE001
        return None


def _retry_after(headers) -> float | None:
    val = _header(headers, "retry-after") if headers is not None else None
    if not val:
        return None
    try:
        return max(0.0, float(val))
    except ValueError:
        try:
            from email.utils import parsedate_to_datetime

            dt = parsedate_to_datetime(val)
            return max(0.0, (dt - datetime.now(timezone.utc)).total_seconds())
        except Exception:  # noqa: BLE001
            return None


class MubitLLM(_JSONMixin):
    def __init__(self, settings: Settings, log_path: Path | None = None):
        if not settings.mubit_api_key:
            raise LLMError("MUBIT_API_KEY is not set (put it in .env); every call must go through Mubit")
        if "mubit" not in settings.base_url:
            # Hard rule for this project: never talk to a provider directly.
            raise LLMError(f"base URL {settings.base_url!r} is not a Mubit gateway URL")
        self.settings = settings
        self.provider = settings.provider
        self.model = settings.model
        self.log_path = log_path
        self._log_lock = threading.Lock()
        self._openai_metadata_mode = "metadata"  # -> "store" -> "none" if the gateway rejects it
        self.sleep: Callable[[float], None] = time.sleep
        if self.provider == "anthropic":
            import anthropic

            self._client = anthropic.Anthropic(
                base_url=settings.base_url, api_key=settings.mubit_api_key, max_retries=0
            )
        elif self.provider == "openai":
            import openai

            self._client = openai.OpenAI(
                base_url=settings.base_url, api_key=settings.mubit_api_key, max_retries=0
            )
        else:
            raise LLMError(f"unsupported provider {self.provider!r}")

    # -- provider calls: return (text, request_id, input_tokens, output_tokens, model)

    def _call_anthropic(self, system: str, user: str, session_id: str, max_tokens: int):
        raw = self._client.messages.with_raw_response.create(
            model=self.model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
            metadata={"user_id": session_id},
        )
        rid = _header(raw.headers, "x-middleware-request-id")
        msg = raw.parse()
        text = "".join(
            getattr(b, "text", "") for b in msg.content if getattr(b, "type", "") == "text"
        )
        usage = getattr(msg, "usage", None)
        return (
            text,
            rid,
            getattr(usage, "input_tokens", None),
            getattr(usage, "output_tokens", None),
            getattr(msg, "model", None) or self.model,
        )

    def _call_openai(self, system: str, user: str, session_id: str, max_tokens: int):
        import openai

        kwargs: dict = dict(
            model=self.model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            max_completion_tokens=max_tokens,
        )
        while True:
            mode = self._openai_metadata_mode
            extra: dict = {}
            if mode in ("metadata", "store"):
                extra["metadata"] = {"session_id": session_id}
            if mode == "store":
                extra["store"] = True
            try:
                raw = self._client.chat.completions.with_raw_response.create(**kwargs, **extra)
                break
            except openai.BadRequestError as e:
                body = str(e).lower()
                if mode != "none" and ("metadata" in body or "store" in body):
                    self._openai_metadata_mode = "store" if mode == "metadata" else "none"
                    continue
                raise
        rid = _header(raw.headers, "x-middleware-request-id")
        resp = raw.parse()
        text = (resp.choices[0].message.content or "") if resp.choices else ""
        usage = getattr(resp, "usage", None)
        return (
            text,
            rid,
            getattr(usage, "prompt_tokens", None),
            getattr(usage, "completion_tokens", None),
            getattr(resp, "model", None) or self.model,
        )

    def _is_retryable(self, exc: Exception) -> tuple[bool, float | None, str | None]:
        """(retry?, wait seconds from retry-after, request id if any)."""
        status = getattr(exc, "status_code", None)
        resp = getattr(exc, "response", None)
        headers = getattr(resp, "headers", None)
        rid = _header(headers, "x-middleware-request-id") if headers is not None else None
        if status is None:
            # connection errors / timeouts: safe to retry
            name = type(exc).__name__
            return ("Connection" in name or "Timeout" in name), None, rid
        if _header(headers, "x-should-retry") == "false" and status not in RETRY_STATUSES:
            return False, None, rid
        overloaded = "overloaded" in str(exc).lower()
        if status in RETRY_STATUSES or overloaded:
            return True, _retry_after(headers), rid
        return False, None, rid

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult:
        system = load_prompt(role)
        call = self._call_anthropic if self.provider == "anthropic" else self._call_openai
        t0 = time.monotonic()
        last_exc: Exception | None = None
        for attempt in range(1, MAX_TRIES + 1):
            try:
                text, rid, tin, tout, model = call(system, user, session_id, max_tokens)
            except Exception as e:  # noqa: BLE001
                last_exc = e
                retry, wait, rid = self._is_retryable(e)
                if not retry or attempt == MAX_TRIES:
                    self._log(
                        role=role, session_id=session_id, model=self.model, request_id=rid,
                        latency_ms=int((time.monotonic() - t0) * 1000), input_tokens=None,
                        output_tokens=None, user_chars=len(user), reply_chars=0,
                        error=f"{type(e).__name__}: {str(e)[:300]}",
                    )
                    self._trace(role, session_id, system, user, None, rid=rid, model=self.model,
                                error=f"{type(e).__name__}: {str(e)[:2000]}")
                    raise LLMError(f"{role} call failed: {type(e).__name__}: {e}") from e
                self.sleep(min(wait if wait is not None else 2.0 * attempt, MAX_RETRY_WAIT_S))
                continue
            res = LLMResult(
                text=text,
                role=role,
                request_id=rid,
                model=model,
                latency_ms=int((time.monotonic() - t0) * 1000),
                input_tokens=tin,
                output_tokens=tout,
            )
            self._log(
                role=role, session_id=session_id, model=model, request_id=rid,
                latency_ms=res.latency_ms, input_tokens=tin, output_tokens=tout,
                user_chars=len(user), reply_chars=len(text),
            )
            self._trace(role, session_id, system, user, text, rid=rid, model=model,
                        latency_ms=res.latency_ms, input_tokens=tin, output_tokens=tout)
            return res
        raise LLMError(f"{role} call failed: {last_exc}")  # pragma: no cover

    def _trace(self, role: str, session_id: str, system: str, user: str, reply: str | None, **meta) -> None:
        """Save the full call (prompt and reply) as traces/<time>-<role>-<request id>.json next to the
        call log, so every Mubit example can be read back and shown later."""
        if self.log_path is None:
            return
        now = datetime.now(timezone.utc)
        rid = meta.get("rid") or "no-id"
        rec = {"ts": now.isoformat(timespec="seconds"), "role": role, "session_id": session_id,
               "request_id": meta.pop("rid", None), "system_prompt": f"{role}.md",
               "system_sha256": hashlib.sha256(system.encode("utf-8")).hexdigest()[:16],
               **meta, "user": user, "reply": reply}
        path = self.log_path.parent / "traces" / f"{now.strftime('%Y%m%dT%H%M%S%f')}-{role}-{rid}.json"
        with self._log_lock:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(rec, ensure_ascii=False, indent=1), encoding="utf-8")

    def _log(self, **fields) -> None:
        if self.log_path is None:
            return
        rec = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), **fields}
        line = json.dumps(rec, ensure_ascii=False)
        with self._log_lock:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")


# ---------------------------------------------------------------------------------------------
# Fake


@dataclass
class FakeCall:
    role: str
    user: str
    session_id: str
    max_tokens: int


class FakeLLM(_JSONMixin):
    """Scripted LLM for tests and offline runs: pops replies per role, in order.

    `default`, if given, is called as default(role, user) when a role's list is empty.
    """

    def __init__(
        self,
        responses: dict[str, list[str]],
        default: Callable[[str, str], str] | None = None,
        log_path: Path | None = None,
    ):
        self.responses = {k: list(v) for k, v in responses.items()}
        self.default = default
        self.log_path = log_path
        self.calls: list[FakeCall] = []

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult:
        if role not in ROLES:
            raise LLMError(f"unknown role {role!r}")
        self.calls.append(FakeCall(role, user, session_id, max_tokens))
        queue = self.responses.get(role) or []
        if queue:
            text = queue.pop(0)
        elif self.default is not None:
            text = self.default(role, user)
        else:
            raise LLMError(f"FakeLLM has no scripted reply left for role {role!r}")
        res = LLMResult(
            text=text, role=role, request_id=f"fake-{len(self.calls)}", model="fake",
            latency_ms=0, input_tokens=None, output_tokens=None,
        )
        if self.log_path is not None:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    "role": role, "session_id": session_id, "model": "fake",
                    "request_id": res.request_id, "latency_ms": 0, "input_tokens": None,
                    "output_tokens": None, "user_chars": len(user), "reply_chars": len(text),
                }) + "\n")
        return res


def fake_default_reply(role: str, user: str) -> str:
    """Minimal valid replies so `FORGE_FAKE_LLM=1` can drive the whole loop offline."""
    if role == "designer":
        return json.dumps({
            "title": "Coin Dash",
            "slug": "coin-dash",
            "pitch": "Grab glowing coins before the timer runs out.",
            "core_loop": "Run around, touch coins to collect them, coins respawn.",
            "modules": [
                {"path": "ReplicatedStorage/Config.luau", "purpose": "Tunable numbers", "depends": []},
                {"path": "ServerScriptService/Game.server.luau", "purpose": "Builds map, spawns coins",
                 "depends": ["ReplicatedStorage/Config.luau"]},
                {"path": "StarterPlayerScripts/Hud.client.luau", "purpose": "Shows coin count",
                 "depends": ["ReplicatedStorage/Config.luau"]},
            ],
            "acceptance": ["map is built", "coins can be collected"],
        })
    if role in ("coder", "fixer"):
        m = re.search(r"^path:\s*(\S+)", user, re.MULTILINE)
        path = m.group(1) if m else ""
        if path.endswith(".server.luau") or path.endswith(".client.luau"):
            body = f'print("[forge fake] {path} running")'
        else:
            body = "local M = {}\n\nreturn M"
        return f"```luau\n{body}\n```"
    if role == "critic":
        return json.dumps({"score": 5, "summary": "fake critique", "issues": [], "done": False})
    if role == "reflector":
        return "# Lessons\n\n- Use task.wait, never wait().\n"
    raise LLMError(f"unknown role {role!r}")


def make_llm(settings: Settings, log_path: Path | None) -> LLM:
    """FakeLLM if FORGE_FAKE_LLM=1 (scripted from FORGE_FAKE_LLM_FILE json if set), else MubitLLM."""
    if os.environ.get("FORGE_FAKE_LLM") == "1":
        responses: dict[str, list[str]] = {}
        script = os.environ.get("FORGE_FAKE_LLM_FILE")
        if script:
            responses = json.loads(Path(script).read_text(encoding="utf-8"))
        return FakeLLM(responses, default=fake_default_reply, log_path=log_path)
    if not settings.mubit_api_key:
        raise LLMError(
            "MUBIT_API_KEY is not set. Add it to .env (keys start with mbt_), "
            "or set FORGE_FAKE_LLM=1 for an offline run."
        )
    return MubitLLM(settings, log_path)
