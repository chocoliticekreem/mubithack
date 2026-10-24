"""LLM clients for forge. Every real call goes through the Mubit gateway.

Mubit groups calls into tasks by (system prompt, tools, output format, model), so each role's
system prompt is a fixed file in forge/prompts/<role>.md, loaded once and never modified per call.
Everything that varies goes in the user message.
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Protocol

from forge.config import Settings

PROMPTS_DIR = Path(__file__).resolve().parent / "prompts"
# mubit-tester's roles (player, judge, explorer) keep their prompts in mubit-tester/prompts/.
PROMPT_DIRS = (PROMPTS_DIR, Path(__file__).resolve().parent.parent / "mubit-tester" / "prompts")
ROLES = ("designer", "coder", "fixer", "critic", "reflector", "player", "judge",
         "auditor", "verifier", "triage", "investigator", "patcher", "planner", "scenarist",
         "check_reviewer", "reproducer", "director", "fun_critic", "gap_finder", "code_judge")

MAX_TRIES = 3  # total attempts for retryable gateway errors (503 / 529 overloaded / connection)
RATE_LIMIT_TRIES = 6  # 429s get more attempts: with --jobs 8 a burst can trip the gateway's rate limit
RETRY_STATUSES = {429, 503, 529}
MAX_RETRY_WAIT_S = 60.0
JSON_REPAIRS = 2
DEFAULT_JOBS = 8  # concurrent LLM calls (forge new/run/feature --jobs N, or FORGE_JOBS)
# Roles whose reply is cached on disk by (system prompt, model, max_tokens, user message). The fixer and
# patcher are cached only for compile-error repairs (COMPILE_FIX_MARK in the message): a critic, improve or
# human fix must always reach Mubit, so a retry gets a fresh attempt and a correction stays a training call.
CACHE_ROLES = ("designer", "director", "coder", "planner", "critic", "fun_critic", "reflector")
COMPILE_FIX_ROLES = ("fixer", "patcher")
COMPILE_FIX_MARK = "luau-compile failed"
# Early abort: a code role that has written this many chars without opening a fence (or a JSON role
# without a "{") is writing prose; stop paying for it and let the role's repair/retry path take over.
ABORT_AFTER_CHARS = 1500
LUAU_ROLES = ("coder", "fixer")
JSON_ROLES = ("designer", "director", "critic", "fun_critic", "planner", "patcher", "auditor", "verifier", "triage", "investigator")
# A reply written as a tool call instead of the JSON the prompt asks for: <invoke name="probe"><parameter
# name="code">...</parameter></invoke>, often with an XML namespace prefix on the tags. 42% of the real
# investigator calls (348 of 827) were repair calls for exactly this, so it is parsed locally instead.
_NS = r"(?:[A-Za-z_][\w.-]*:)?"
_TOOL_CALL = re.compile(r"<" + _NS + r"invoke\s+name=\"([^\"]+)\"\s*>(.*?)</" + _NS + r"invoke>", re.DOTALL)
_TOOL_PARAM = re.compile(r"<" + _NS + r"parameter\s+name=\"([^\"]+)\"\s*>(.*?)</" + _NS + r"parameter>", re.DOTALL)
_TOOL_OPEN = re.compile(r"<" + _NS + r"(?:invoke|parameter)\s+name=\"")
SKIPPED_LOG = "skipped.jsonl"  # next to calls.jsonl: Mubit calls Forge did not need (cache hits, repairs avoided)


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
    cached: bool = False   # served from the on-disk reply cache (no Mubit call)
    aborted: bool = False  # streaming stopped early: the reply was going nowhere


def jobs_from_env(default: int = DEFAULT_JOBS) -> int:
    try:
        return max(1, int(os.environ.get("FORGE_JOBS") or default))
    except ValueError:
        return default


def estimate_tokens(text: str) -> int:
    """Rough output-token count for a reply whose real usage we never got (cut-short streams).
    Luau runs about 3 characters per token on Mubit's Anthropic models."""
    return (len(text) + 2) // 3


def stream_verdict(role: str, text: str) -> str:
    """While a reply streams in: "abort" (prose where code/JSON should be), "done" (a code reply's
    ```luau block has closed, the rest is commentary) or "more"."""
    if role in LUAU_ROLES:
        opened = re.search(r"```[ \t]*(?:luau|lua)[ \t]*\r?\n", text, re.IGNORECASE)
        if opened is None:
            return "abort" if len(text) >= ABORT_AFTER_CHARS and "```" not in text else "more"
        return "done" if "```" in text[opened.end():] else "more"
    if role in JSON_ROLES and len(text) >= ABORT_AFTER_CHARS and "{" not in text and not _TOOL_OPEN.search(text):
        return "abort"  # (a tool-call reply is not prose: it is parsed locally, see _salvage_tool_call)
    return "more"


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


def extract_json_object(text: str, required: list[str] | None = None) -> dict:
    """Return the first JSON object in text. Fenced ```json blocks are tried first.

    With `required`, the first object that has all those keys wins over an earlier one that does not
    (a fence or a `{}` quoted inside the reply's own strings must not shadow the real reply).
    Raises ValueError with a short reason if none parses.
    """
    return parse_reply(text, required)[0]


def parse_reply(text: str, required: list[str] | None = None) -> tuple[dict, str]:
    """(object, how) for a JSON-role reply. how is "json" for a clean parse; with `required`, a reply that
    only parses after a local fix-up says which one, and saves the repair call it used to cost:
    "lenient" (raw tabs/newlines inside strings, e.g. a patcher's Luau), "bracket" (one closer too many)
    or "tool_call" (written as <invoke name=...> instead of JSON). Raises ValueError if none parses."""
    if required:
        first: dict | None = None
        for strict, how in ((True, "json"), (False, "lenient")):
            for obj in _json_objects(text, strict=strict):
                if all(k in obj for k in required):
                    return obj, how
                if first is None:
                    first = obj
        for salvage, how in ((_salvage_json, "bracket"), (_salvage_tool_call, "tool_call")):
            obj = salvage(text)
            if obj is not None and all(k in obj for k in required):
                return obj, how
        if first is not None:
            return first, "json"
    return _first_json_object(text), "json"


def _param_value(raw: str) -> Any:
    """A tool-call parameter: JSON when it is a JSON object, array, number, bool or null, else the text."""
    text = raw.strip("\n")
    try:
        val = json.loads(text)
    except ValueError:
        return text
    return text if isinstance(val, str) else val


def _salvage_tool_call(text: str) -> dict | None:
    """<invoke name="probe"><parameter name="code">...</parameter></invoke> -> {"action": "probe", "code": ...}.
    Only the first complete call counts (one action per reply); without one, bare <parameter> tags are read
    (their "action" parameter names the action). A cut-off call has no closing tag and is not used."""
    m = _TOOL_CALL.search(text)
    obj: dict = {"action": m.group(1)} if m else {}
    for name, raw in _TOOL_PARAM.findall(m.group(2) if m else text):
        obj.setdefault(name, _param_value(raw))
    return obj or None


def _salvage_json(text: str, max_edits: int = 3) -> dict | None:
    """Fix the commonest model slip locally instead of paying for a repair call: a stray closing
    bracket (e.g. `}]]` for `}]`). Drops the closer the parser chokes on, up to max_edits times."""
    start = text.find("{")
    if start == -1:
        return None
    s = text[start:]
    for _ in range(max_edits + 1):
        try:
            obj, _ = json.JSONDecoder().raw_decode(s)
            return obj if isinstance(obj, dict) else None
        except json.JSONDecodeError as e:
            if e.pos >= len(s) or s[e.pos] not in "]}":
                return None
            s = s[:e.pos] + s[e.pos + 1:]
    return None


def _json_objects(text: str, strict: bool = True):
    """Every top-level JSON object in text, in the order extract_json_object tries them. strict=False also
    accepts raw control characters (tabs, newlines) inside strings."""
    candidates = [m.group(2) for m in _FENCE_RE.finditer(text) if m.group(1).lower() in ("json", "", "jsonc")]
    candidates.append(text)
    decoder = json.JSONDecoder(strict=strict)
    for cand in candidates:
        start = cand.find("{")
        while start != -1:
            try:
                obj, end = decoder.raw_decode(cand, start)
            except json.JSONDecodeError:
                start = cand.find("{", start + 1)
                continue
            if isinstance(obj, dict):
                yield obj
                start = cand.find("{", end)
            else:
                start = cand.find("{", start + 1)


def _first_json_object(text: str) -> dict:
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
                obj, how = parse_reply(res.text, required)
                _check_required(obj, required)
            except ValueError as e:
                if attempt == JSON_REPAIRS:
                    raise LLMError(
                        f"{role}: no valid JSON after {JSON_REPAIRS} repairs: {e}"
                    ) from e
                msg = _repair_message(user, str(e), res.text)
                continue
            if how != "json":
                note_skipped(self, kind="repair_avoided", how=how, role=role, session_id=session_id,
                             request_id=res.request_id, input_tokens=res.input_tokens)
            return obj, res
        raise LLMError("unreachable")  # pragma: no cover


_SKIP_LOCK = threading.Lock()


def note_skipped(llm: Any, **fields) -> None:
    """Record a Mubit call Forge did not need (a reply-cache hit, a JSON repair parsed away) in skipped.jsonl
    next to the client's calls.jsonl, which stays the log of real Mubit calls. `forge reflect` reads both."""
    log_path = getattr(llm, "log_path", None)
    if not isinstance(log_path, (str, Path)):
        return
    rec = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), **fields}
    path = Path(log_path).with_name(SKIPPED_LOG)
    try:
        with _SKIP_LOCK:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass  # bookkeeping never fails a call


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
        # Streaming lets a reply stop early (stream_verdict). FORGE_STREAM=0 turns it off; a gateway
        # that rejects streaming turns it off for the rest of the process.
        self.stream = os.environ.get("FORGE_STREAM", "1") != "0"
        self._tl = threading.local()  # role / abort flag of the call running on this thread
        # A 429 on one thread makes every thread wait it out, so a burst backs off together.
        self._cool_lock = threading.Lock()
        self._cool_until = 0.0
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
        if self.stream:
            try:
                return self._stream_anthropic(system, user, session_id, max_tokens)
            except Exception as e:  # noqa: BLE001
                if getattr(e, "status_code", None) not in (400, 404, 405, 415, 501) or "stream" not in str(e).lower():
                    raise
                self.stream = False  # this gateway does not stream: plain calls from now on
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

    def _stream_anthropic(self, system: str, user: str, session_id: str, max_tokens: int):
        """Streamed call: reads until the reply ends, a code reply's block closes, or stream_verdict
        says it is going nowhere (then self._tl.aborted is set and the partial text is returned)."""
        role = getattr(self._tl, "role", "")
        with self._client.messages.stream(
            model=self.model, max_tokens=max_tokens, system=system,
            messages=[{"role": "user", "content": user}], metadata={"user_id": session_id},
        ) as stream:
            rid = _header(stream.response.headers, "x-middleware-request-id")
            parts: list[str] = []
            n = 0
            stopped = False
            for chunk in stream.text_stream:
                parts.append(chunk)
                before, n = n, n + len(chunk)
                # judge only when it can change: a fence arrived, or the abort threshold was crossed
                if "`" in chunk or (before < ABORT_AFTER_CHARS <= n):
                    verdict = stream_verdict(role, "".join(parts))
                    if verdict != "more":
                        self._tl.aborted = verdict == "abort"
                        stopped = True
                        break
            text = "".join(parts)
            msg = stream.current_message_snapshot if stopped else stream.get_final_message()
        usage = getattr(msg, "usage", None)
        out_tokens = getattr(usage, "output_tokens", None)
        if stopped:
            # a stream we cut short never gets its final usage (the snapshot still holds message_start's
            # ~1-5 tokens): estimate from what actually arrived so bench/ledger token counts stay honest
            out_tokens = max(out_tokens or 0, estimate_tokens(text))
        return (text, rid, getattr(usage, "input_tokens", None), out_tokens,
                getattr(msg, "model", None) or self.model)

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

    def _wait_cooldown(self) -> None:
        """Wait out a 429 cooldown set by another thread (not one this thread already slept through)."""
        with self._cool_lock:
            until = self._cool_until
            if until <= getattr(self._tl, "slept_until", 0.0):
                return
            rem = until - time.monotonic()
        if rem > 0:
            self._tl.slept_until = until
            self.sleep(min(rem, MAX_RETRY_WAIT_S))

    def _backoff(self, wait: float) -> None:
        with self._cool_lock:
            self._cool_until = max(self._cool_until, time.monotonic() + wait)
            self._tl.slept_until = self._cool_until
        self.sleep(wait)

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult:
        system = load_prompt(role)
        call = self._call_anthropic if self.provider == "anthropic" else self._call_openai
        t0 = time.monotonic()
        self._tl.role = role
        attempt = 0
        while True:
            attempt += 1
            self._tl.aborted = False
            self._wait_cooldown()
            try:
                text, rid, tin, tout, model = call(system, user, session_id, max_tokens)
            except Exception as e:  # noqa: BLE001
                retry, wait, rid = self._is_retryable(e)
                limit = RATE_LIMIT_TRIES if getattr(e, "status_code", None) == 429 else MAX_TRIES
                if not retry or attempt >= limit:
                    self._log(
                        role=role, session_id=session_id, model=self.model, request_id=rid,
                        latency_ms=int((time.monotonic() - t0) * 1000), input_tokens=None,
                        output_tokens=None, user_chars=len(user), reply_chars=0,
                        error=f"{type(e).__name__}: {str(e)[:300]}",
                    )
                    self._trace(role, session_id, system, user, None, rid=rid, model=self.model,
                                error=f"{type(e).__name__}: {str(e)[:2000]}")
                    raise LLMError(f"{role} call failed: {type(e).__name__}: {e}") from e
                if wait is None:  # exponential with jitter, so a burst of threads does not retry in step
                    wait = 2.0 * attempt if attempt < 3 else 2.0 ** attempt
                    wait += random.uniform(0, 0.25 * attempt) if attempt > 1 else 0.0
                self._backoff(min(wait, MAX_RETRY_WAIT_S))
                continue
            res = LLMResult(
                text=text,
                role=role,
                request_id=rid,
                model=model,
                latency_ms=int((time.monotonic() - t0) * 1000),
                input_tokens=tin,
                output_tokens=tout,
                aborted=bool(getattr(self._tl, "aborted", False)),
            )
            self._log(
                role=role, session_id=session_id, model=model, request_id=rid,
                latency_ms=res.latency_ms, input_tokens=tin, output_tokens=tout,
                user_chars=len(user), reply_chars=len(text),
                **({"aborted": True} if res.aborted else {}),
            )
            self._trace(role, session_id, system, user, text, rid=rid, model=model,
                        latency_ms=res.latency_ms, input_tokens=tin, output_tokens=tout)
            return res

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
        latency: dict[str, float] | float | None = None,
    ):
        self.responses = {k: list(v) for k, v in responses.items()}
        self.default = default
        self.log_path = log_path
        self.calls: list[FakeCall] = []
        # simulated seconds per call (per role, or one number): profiles the loop's structure offline
        self.latency = latency
        self._lock = threading.Lock()
        self._active = 0           # calls running right now
        self.peak_concurrency = 0  # most calls running at once

    def _delay(self, role: str) -> float:
        if isinstance(self.latency, dict):
            return float(self.latency.get(role, 0.0))
        return float(self.latency or 0.0)

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult:
        if role not in ROLES:
            raise LLMError(f"unknown role {role!r}")
        with self._lock:
            self.calls.append(FakeCall(role, user, session_id, max_tokens))
            n_call = len(self.calls)
            queue = self.responses.get(role) or []
            text = queue.pop(0) if queue else None
            self._active += 1
            self.peak_concurrency = max(self.peak_concurrency, self._active)
        try:
            delay = self._delay(role)
            if delay > 0:
                time.sleep(delay)
            if text is None:
                if self.default is None:
                    raise LLMError(f"FakeLLM has no scripted reply left for role {role!r}")
                text = self.default(role, user)
        finally:
            with self._lock:
                self._active -= 1
        res = LLMResult(
            text=text, role=role, request_id=f"fake-{n_call}", model="fake",
            latency_ms=int(self._delay(role) * 1000), input_tokens=None, output_tokens=None,
        )
        if self.log_path is not None:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self._lock, self.log_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    "role": role, "session_id": session_id, "model": "fake",
                    "request_id": res.request_id, "latency_ms": res.latency_ms, "input_tokens": None,
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
    if role == "director":
        return json.dumps({
            "fantasy": "You dash around grabbing glowing coins", "core_loop": "run -> grab coins -> score climbs",
            "progression": [], "systems": [{"name": "Coins", "what": "spawn and collect",
                                            "module": "ServerScriptService/Game.server.luau"}],
            "juice": [{"moment": "coin collected", "sound": "coin ding", "vfx": "sparkle burst",
                       "ui": "counter punch", "camera": "none"}],
            "first_60_seconds": [{"t": 5, "beat": "grabs the first coin", "counter": "coins_collected", "min": 1}],
            "rewards": [], "visual_style": {"palette": ["#FFC429"], "materials": ["SmoothPlastic"]},
            "sounds": [{"id": "Coin", "for": "coin", "describe": "coin ding"}], "module_budget": 4,
            "acceptance": ["coins can be collected"],
        })
    if role == "fun_critic":
        return json.dumps({"scores": {"fun": 5, "juice": 5, "clarity": 5, "visuals": 5},
                           "summary": "fake fun critique", "issues": []})
    raise LLMError(f"unknown role {role!r}")


def make_llm(settings: Settings, log_path: Path | None) -> LLM:
    """FakeLLM if FORGE_FAKE_LLM=1 (scripted from FORGE_FAKE_LLM_FILE json if set), else MubitLLM."""
    if os.environ.get("FORGE_FAKE_LLM") == "1":
        responses: dict[str, list[str]] = {}
        script = os.environ.get("FORGE_FAKE_LLM_FILE")
        if script:
            responses = json.loads(Path(script).read_text(encoding="utf-8"))
        latency: dict[str, float] | float | None = None
        raw = os.environ.get("FORGE_FAKE_LATENCY")  # "2.5" or '{"coder": 30, "critic": 14}'
        if raw:
            latency = json.loads(raw) if raw.strip().startswith("{") else float(raw)
        return FakeLLM(responses, default=fake_default_reply, log_path=log_path, latency=latency)
    if not settings.mubit_api_key:
        raise LLMError(
            "MUBIT_API_KEY is not set. Add it to .env (keys start with mbt_), "
            "or set FORGE_FAKE_LLM=1 for an offline run."
        )
    llm = MubitLLM(settings, log_path)
    if os.environ.get("FORGE_NO_CACHE") == "1":
        return llm
    return CachedLLM(llm, settings.runs_dir / ".cache" / "llm")


# ---------------------------------------------------------------------------------------------
# Reply cache


class CachedLLM(_JSONMixin):
    """On-disk reply cache in front of any LLM, for CACHE_ROLES (and compile-error fixes).

    Key = sha256(role, sha256(system prompt), model, max_tokens, user message). Everything a reply
    depends on is in the key: an edited system prompt, a different model, or any change to the module,
    its deps, the spec or the lessons (all in the user message) is a miss. A hit returns the stored
    reply with cached=True and makes no Mubit call. Cut-off and early-aborted replies are not stored.
    Files live in runs/.cache/llm/<role>/<key>.json; FORGE_NO_CACHE=1 (or --no-cache) skips the cache.
    """

    def __init__(self, inner: Any, cache_dir: Path, roles: tuple[str, ...] = CACHE_ROLES):
        self.inner = inner
        self.dir = Path(cache_dir)
        self.roles = set(roles)
        self.hits = 0
        self.misses = 0
        self._lock = threading.Lock()

    def key(self, role: str, user: str, max_tokens: int) -> str:
        system = load_prompt(role)
        model = getattr(self.inner, "model", "")
        h = hashlib.sha256()
        for part in (role, hashlib.sha256(system.encode("utf-8")).hexdigest(), str(model), str(max_tokens), user):
            h.update(part.encode("utf-8"))
            h.update(b"\x00")
        return h.hexdigest()

    def _path(self, role: str, key: str) -> Path:
        return self.dir / role / f"{key}.json"

    def cacheable(self, role: str, user: str) -> bool:
        return role in self.roles or (role in COMPILE_FIX_ROLES and COMPILE_FIX_MARK in user)

    def complete(self, role: str, user: str, *, session_id: str, max_tokens: int = 4096) -> LLMResult:
        if not self.cacheable(role, user):
            return self.inner.complete(role, user, session_id=session_id, max_tokens=max_tokens)
        key = self.key(role, user, max_tokens)
        path = self._path(role, key)
        if path.exists():
            try:
                rec = json.loads(path.read_text(encoding="utf-8"))
                with self._lock:
                    self.hits += 1
                note_skipped(self.inner, kind="cache_hit", role=role, session_id=session_id,
                             request_id=rec.get("request_id"), input_tokens=rec.get("input_tokens"),
                             output_tokens=rec.get("output_tokens"), latency_ms=rec.get("latency_ms"))
                return LLMResult(text=rec["text"], role=role, request_id=rec.get("request_id"),
                                 model=rec.get("model", ""), latency_ms=0, input_tokens=rec.get("input_tokens"),
                                 output_tokens=rec.get("output_tokens"), cached=True)
            except (OSError, ValueError, KeyError):
                pass  # unreadable entry: call again and overwrite it
        with self._lock:
            self.misses += 1
        res = self.inner.complete(role, user, session_id=session_id, max_tokens=max_tokens)
        cut = res.output_tokens is not None and res.output_tokens >= max_tokens
        if res.text.strip() and not res.aborted and not cut:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(f".{threading.get_ident()}.tmp")
            tmp.write_text(json.dumps({"role": role, "text": res.text, "request_id": res.request_id,
                                       "model": res.model, "input_tokens": res.input_tokens,
                                       "output_tokens": res.output_tokens, "latency_ms": res.latency_ms,
                                       "session_id": session_id,
                                       "ts": datetime.now(timezone.utc).isoformat(timespec="seconds")}),
                           encoding="utf-8")
            tmp.replace(path)
        return res

    def __getattr__(self, name):
        return getattr(self.inner, name)
