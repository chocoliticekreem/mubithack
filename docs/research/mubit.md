# Mubit — research notes (2026-10-23)

Sources cloned/fetched from docs.mubit.ai/llms-full.txt (vendored in docs/vendor/mubit/), github.com/MubitLabs/latte-bench.

I couldn't find any documented API for sending feedback, scores or corrections to Mubit, and there is no documented way for our app to call an adapter through the API. Both matter for our design. The docs say "There is no Mubit model ID: you can't send a call to an adapter by naming it as the model", and the only place to try an adapter is the console's **Try models** page. Everything else is well documented in full-text docs at https://docs.mubit.ai/llms-full.txt, which I read end to end.

Below, **[DOC]** means stated in Mubit's docs or source, **[SRC]** means seen in Mubit's own code, **[INF]** is my inference, and **[NOT DOC]** means I looked and found nothing. The relevant sources were cloned into `/private/tmp/claude-501/-Users-arvin-orca-mubithack/9f166624-9a81-4d4e-ad65-0200f1e52a40/scratchpad/`; nothing was written to the repo.

---

## 0. The product we're using
- The docs describe Mubit as a proxy. It "passes your app's calls on to your model provider and records them. It groups similar calls into tasks and trains adapters, small models each made for one task. Each adapter version is tested against your provider model's answers." [DOC] https://docs.mubit.ai/index.md
- Console: https://app.mubit.ai/console/ · API: https://api.mubit.ai [DOC] https://docs.mubit.ai/llms.txt
- **Watch out for older material.** Mubit also has a separate memory SDK (`mubit-sdk` / `@mubit-ai/sdk` with `remember`, `recall`, `record_outcome`, `feedback`; env vars `MUBIT_ENDPOINT` and `MUBIT_API_KEY`; console.mubit.ai). Mubit's own integration skill says the two are "different surfaces" and warns: "Do not infer training, model export or serving methods from the marketing copy." [DOC] https://mubit.ai/.well-known/agent-skills/mubit-integration/SKILL.md
  - The memory SDK's routes (`/v2/control/*`) return 404 on api.mubit.ai today; I checked live.
  - The mubit.ai homepage, llms.txt and agents.md still link to old pages (`/getting-started`, `/patterns/outcome-attribution-loop`, `/sdk/llm-providers`). All of them now return 404.

## 1. Base URLs, auth, API shapes
**Base URLs** (each SDK takes its own) [DOC] https://docs.mubit.ai/reference/api.md
| SDK | Base URL |
|---|---|
| OpenAI | `https://api.mubit.ai/openai/v1` |
| Anthropic | `https://api.mubit.ai/anthropic` (no `/v1`) |
| Gemini (google-genai) | `https://api.mubit.ai/gemini` (no `/v1beta`) |
| OpenAI SDK on Gemini | `https://api.mubit.ai/gemini/v1beta/openai` |
| OpenRouter / Groq / Together / Mistral | `https://api.mubit.ai/compat/{openrouter\|groq\|together\|mistral}/v1` |

- The docs say to "use the base URL your console's Connect page shows" because regions may differ: a `wrong_region` 401 names the right one. [DOC]

**Paths that work:** [DOC] https://docs.mubit.ai/guides/connect-http.md
- OpenAI: `/chat/completions`, `/responses`, `/embeddings`, `/models`. "Chat Completions and Responses both work through the same base URL." https://docs.mubit.ai/guides/connect-openai.md
- Anthropic: `/v1/messages`, `/v1/messages/count_tokens`, `/v1/models`.
- Gemini: `:generateContent`, `:streamGenerateContent?alt=sse`, `/models`.
- Compat services: `/chat/completions`, `/embeddings`, `/models`, `/models/{id}`.
- Anything else gets `404 unknown_route`. Provider admin endpoints get `403 admin_path_refused`.

**Auth:** send the key in the provider's own header. Keys start with `mbt_`. [DOC]
- OpenAI and compat: `Authorization: Bearer mbt_…`
- Anthropic: `x-api-key: mbt_…` or `Authorization: Bearer`
- Gemini: `x-goog-api-key` (header only, not `?key=`)
- Send exactly one key. A provider key, a sign-in or OAuth token, a JWT, or a second credential gets a 401 (`provider_key_refused`, `subscription_token_refused`, `jwt_refused`, `extra_credential_refused`).
- Inference keys can call; read-only keys get `403 key_permission`. https://docs.mubit.ai/admin/mubit-keys.md

**Env vars:**
- `MUBIT_API_KEY` is the convention throughout the docs. [DOC]
- Zero-code OpenAI: `OPENAI_BASE_URL=https://api.mubit.ai/openai/v1`, `OPENAI_API_KEY=$MUBIT_API_KEY`. [DOC]
- Zero-code Anthropic: `ANTHROPIC_BASE_URL=https://api.mubit.ai/anthropic`, `ANTHROPIC_API_KEY=$MUBIT_API_KEY`, and `unset ANTHROPIC_AUTH_TOKEN`. [DOC]
- Latte Bench uses `MUBIT_BASE_URL=https://api.mubit.ai/openai/v1/`, `MUBIT_API_KEY`, `MUBIT_MODEL` and `MUBIT_EXTRA_BODY`. [SRC] latte-bench `.env.example`

**Streaming:** works as each provider normally does. [DOC] reference/api#streaming

**Tool calling:**
- Requests pass through unchanged. Tools and `tool_choice` are part of how a task is identified (section 3).
- Adapter tests have a `Malformed tool calls` result, so adapters are trained on tool-calling tasks. [DOC] guides/first-adapter
- Starter credit refuses hosted tools (web search, file search, code execution, image generation, hosted MCP) and background mode with `400 starter_credit_tools`. [DOC] troubleshooting
- Latte Bench sends structured output (`response_format` json_schema, Anthropic `output_config.format`) through Mubit. [SRC] `scripts/study-provider.js`

**Optional headers Mubit reads:**
- `x-middleware-store: false`, or `x-middleware-record: full|metadata|off`. Anything below `full` means the call is never kept, so it can never train. [DOC]

**Response headers:**
- `x-middleware-request-id: mreq_<32 hex>`, sortable by time, on every response. [DOC] (I confirmed it live.)
- `x-should-retry: false` on errors a retry won't fix; `retry-after` on 429 and 503. [DOC]
- Mubit's own errors use the provider's error format with `type: "middleware_gateway_error"`. [DOC]

**Limits and other details:** [DOC] reference/api
- Timeouts: 10 s to connect (one retry), 610 s to first byte, 15 min of silence, 60 min total.
- Mubit records up to 32 MiB of a request, and the first 4 MiB plus last 256 KiB of a response.
- No CORS, so calls must come from a server.

```python
from openai import OpenAI; import os
client = OpenAI(base_url="https://api.mubit.ai/openai/v1", api_key=os.environ["MUBIT_API_KEY"])
raw = client.chat.completions.with_raw_response.create(
    model="gpt-6-luna",
    messages=[{"role":"system","content":SYSTEM},{"role":"user","content":user}],
    metadata={"session_id": "game-123"})
req_id = raw.headers.get("x-middleware-request-id"); resp = raw.parse()
```

## 2. Models
- **You keep your provider's model IDs.** Mubit passes them through unchanged, and they count toward identifying a task. Date and `-latest` suffixes are stripped when grouping. [DOC] https://docs.mubit.ai/guides/model-ids.md
- **Who pays for calls:**
  - With your own provider key: any model your account can use. [DOC]
  - **Starter credit**: a fixed list of models per provider. Other models get `400 starter_credit_model`, and the error lists what is allowed.
  - Examples in the docs: `gpt-6-luna`, `claude-haiku-4-5`, `gemini-3.8-flash`. [DOC] quickstart
- **Calling an adapter:** "There is no Mubit model ID: you can't send a call to an adapter by naming it as the model. To try an adapter, compare it in Try models." [DOC] guides/model-ids
- **Conflicting claims:**
  - Pricing says "Models serve only after matching or beating your frontier model in evals" and "Download your models". The homepage says "switching over only when it does better". https://mubit.ai/pricing.md, https://mubit.ai
  - The docs say nothing about serving adapters automatically or downloading them. [NOT DOC] Ask the Mubit team at office hours.
- **Base open model for adapters:** not named in the docs [NOT DOC]. One result, `Prompt only`, refers to "the open model the adapter is built on".
- For reference, Banyan Sapling is a LoRA fine-tune of Qwen3-30B-A3B. https://huggingface.co/MubitLabs/banyan-sapling
- **Closed models through Mubit:** Latte Bench's catalogue, pulled through the Mubit gateway on 2026-10-21, lists `gpt-5.5`, `gpt-5.5-pro` (Responses), `gpt-6-luna/sol`, `chat-latest`, `claude-opus-5`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-fable-5-1` and others. [SRC] `docs/model-study/catalogue.json`

## 3. Feedback and corrections, and how calls become a task
**Feedback:**
- **No feedback API is documented.** Not by request ID, score, corrected output or preference. [NOT DOC]
- I checked live: `POST /feedback` and `/v1/feedback` return `404 unknown_route`.
- The only documented feedback is a **"Rate this reply: Good / Bad"** control on a call's detail panel in the console's **Requests** page, plus a `Rating` column. [DOC] https://docs.mubit.ai/guides/requests.md
- Whether a rating changes which examples are kept for training is not stated. [NOT DOC]
- Pricing describes templates that "learn from every reassigned ticket" and "from comments your reviewers keep or dismiss", but doesn't say how. [NOT DOC]

**How adapters are judged:** each version is tested against **your provider model's answers**: "Matched {a}% of your provider model's answers on {n} test cases · needs {need}%". [DOC] guides/first-adapter
- [INF] So an adapter is essentially a copy of the frontier model trained on recorded calls (distillation). The way to make a correction stick is to make the corrected reply a recorded call in the same task.

**Tasks.** Calls are one task when they share all of: [DOC] https://docs.mubit.ai/guides/tasks-and-sessions.md
- the instructions (system prompt: `system`/`developer` messages, Responses `instructions`, Anthropic `system`, Gemini `systemInstruction`)
- tools
- tool choice
- output format
- model

Grouping details:
- Messages after the system prompt don't count. Neither do `temperature` or `max_tokens`.
- Differences in whitespace, numbers, dates and IDs are ignored. Any other changing word in the system prompt starts a new task.
- Tip from the docs: put text that changes per call in the user message.

**Sessions.** A session is the calls of one conversation, taken from the first of these present: [DOC] same page
1. `metadata.thread_id`
2. `metadata.session_id`
3. `metadata.conversation_id`
4. Anthropic `metadata.user_id`
5. Responses `prompt_cache_key`

- If none is present, the session comes from the system prompt plus the first user message.
- **Test cases are split off by session**, so separate sessions are needed for a clean test split.
- Values over 200 characters are hashed.

**Kept example:** a recorded call Mubit accepts for training or testing. "Not every recorded call becomes a kept example." The acceptance rules are not documented. [DOC/NOT DOC]

**Importing past calls:** admins can import from Langfuse, Braintrust or Pydantic Logfire (7, 14 or 30 days back), and Mubit finds tasks in them. [DOC] guides/import-past-calls

## 4. Model updates (adapters)
- **Trigger:** automatic. "By default, a task first trains at 25 kept examples; the count your console shows is the source of truth." [DOC] guides/first-adapter
- **Training must be switched on for the workspace.** Until it is, there is no **Adapters** page. Training controls appear under **Settings** for admins. [DOC]
- **Task status sequence:** `Collecting examples (12 of 25)` → `Reviewing examples` → `Training` → `Testing`. [DOC]
- **How long it takes:** not documented. [NOT DOC] The pricing page says templates train "in minutes".
- **What can delay training:** [DOC]
  - a daily training limit (resets at 00:00 UTC)
  - a pause between trainings
  - `Waiting for more examples` (too few to set some aside for testing)
  - `Waiting for new examples` after a failed run
- **There is no retry button.** Recovery means sending new calls.
- **Reasons a task can't train:** `too few examples`, **`examples too long to train on`**, `the training run failed`, `the first training stopped`. [DOC]
- **Versions:** see **Adapters → History**. Each version gets one result: `Passed` / `Below target` / `Malformed tool calls` / `Prompt only` / `Not tested`. [DOC]
- After a version fails: `Next: a new version after {need} new examples`. [DOC]
- **Deploy and rollback:** marketing and pricing claim "Versions and rollback: Included"; the docs describe neither. [NOT DOC]
- **Comparing quality, cost and latency:**
  - **Try models** with **Side by side** sends the same input to both: "Send to both".
  - Try-models calls are marked "not stored · trains nothing".
  - Daily limits: an org-wide Try-models quota, and **3 adapter starts per UTC day**. The first start "can take a few minutes", retried every 15 s for up to 20 min. [DOC]
  - **Overview** tracks requests, tasks and adapters over time.
  - **Requests** shows response time, a breakdown of where the time went (Mubit vs model), and tokens. [DOC]
  - A cost comparison screen is not documented. [NOT DOC]

## 5. SDKs and console
- **No Mubit-specific SDK is needed for the gateway.** Use the official `openai`, `anthropic` or `google-genai` packages (`npm`: `openai`, `@anthropic-ai/sdk`, `@google/genai`) with the base URL changed. [DOC]
- **Frameworks** (Vercel AI SDK, LangChain, OpenAI Agents SDK): set the base URL. For the Agents SDK, call `setTracingDisabled(true)` first, or it sends your Mubit key to OpenAI. [DOC] guides/frameworks
- **The memory SDK is a separate product:** `pip install mubit-sdk` (0.13.2) and `@mubit-ai/sdk` (0.13.2; `next` 0.14.0-rc.1). [SRC] PyPI/npm
- **Console pages:** Get started, Connect, Requests (filters for task, served-by, errors, session; per-call Good/Bad rating), Tasks, Adapters (History), Try models, Overview, Settings, Mubit keys, Provider keys, Import past calls, Projects. [DOC]
- **Console constraints:** one project per workspace, and the console signs you out after 15 min idle. [DOC]

## 6. Limits, pricing, data requirements, gotchas
**Rate limits:** no numbers are published [NOT DOC]. What is known:
- Starter credit allows `{n}` calls in flight per project, else `429 starter_credit_busy`.
- `503 gateway_overloaded` can occur; honour `retry-after`.
- Starter-credit request bodies: at most 8 MiB, sent within 60 s, plain JSON. [DOC]

**Pricing:** $5 per 1,000 runs, prepaid from $10. https://mubit.ai/pricing.md
- "A run is one request in a task Mubit is learning for you, up to 8,000 tokens in and out. Longer requests count as one extra run per 8,000 tokens."
- Never charged: requests outside a learning task, tokens on your own key, and training, evals or storage.
- Learning is on by default and can be switched off per task.
- Hackathon credits are "$1.5M in Mubit credits for accepted hackers". https://luma.com/nightshift-london

**Data requirements:** 25 kept examples by default before the first training. Enough examples must exist to set some aside as tests, and the split is by session. [DOC]

**Gotchas:**
- **Changing the system prompt starts a new task**, which resets the example count.
- **Long examples can block training** ("examples too long to train on"). This hits code generation with large context.
- **Claude Code isn't covered by the starter credit**; you need your own Anthropic key.
- **Mubit records full content by default.** Keep secrets out of prompts.
- **Launch week is 26–30 Oct ("five major features")**, after our code freeze, so the features we need may not be live yet. https://mubit.ai

## 7. Latte Bench (reference loop) [SRC] github.com/MubitLabs/latte-bench (v0.7.0)
**What it measures:** whether a model planning a simulated latte pour improves over 5 attempts when given feedback. [SRC] README
- The model outputs one plan: `{"parameters":[33 numbers in [0,1]]}`, checked against a strict JSON schema.
- The physics simulation then scores how close the foam pattern is to a heart: `100×max(0,min(IoU, boundaryF1) − 0.25×concavity foam)`, plus serving checks.
- Hidden factors (milk flow, spread, mixing) vary by seed. The model only sees milk volume and temperature.

**The loop**, per attempt (`src/experiments.js` `attemptExperiment`):
1. **Plan call.** Input: target, visible milk state, parameter guide and memory for the mode. If the output fails validation, it gets up to 2 repair calls, each with the error and previous output. Repairs don't use up an attempt.
2. **Run.** The simulation runs with no model calls during the pour, and logs a 60 Hz trace and a 32×32 foam map every second.
3. **Reflect call** (always made, in every mode). Input: the plan, a compact feedback summary (score breakdown, serving checks, and the 32×32 foam map quantised to digits 0–9) and the prior notes. Output: `{"notes": "..."}`, up to 4,000 characters, which **replaces** the previous notes.
4. **Memory modes:**
   - `no-notes`: notes are thrown away.
   - `notes`: the latest note only is carried forward.
   - `raw-history`: all past plans and feedback are carried forward with no truncation.
   - `optimizer`: CMA-ES as a non-LLM baseline.
   - Held-out milk and shape splits freeze memory.

**Engineering choices worth copying:**
- separate calls for planning and for reflection
- strict schemas with a limited number of format repairs
- a cost limit reserved before each call
- every request and response saved
- "no conversation IDs, `store:false`" for isolation

**Results:** "Notes help some models, but not all; these results do not establish learning or transfer." GPT-6 Astra passed 5/15 with notes versus 2/15 without. [SRC] `docs/model-study/methodology.md`

**Caveat:** Latte Bench measures in-context adaptation, not weight updates. Its `.env` says "Learning/training is NOT assumed or enabled without your gateway's contract".
- Its UI shows "adapter activation is unverified". [SRC]

## 8. Routing Claude Code and Codex through Mubit [DOC] https://docs.mubit.ai/guides/claude-code.md, https://docs.mubit.ai/guides/coding-tools.md
**Claude Code:**
- Add your Anthropic API key under **Provider keys**. Pro/Max sign-ins are refused.
- Then:
```bash
export MUBIT_API_KEY='mbt_...'
export ANTHROPIC_BASE_URL=https://api.mubit.ai/anthropic
export ANTHROPIC_AUTH_TOKEN="$MUBIT_API_KEY"      # NOT ANTHROPIC_API_KEY
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5
unset ANTHROPIC_API_KEY
claude -p "Reply with exactly: pong"   # then check Requests; `claude --model claude-opus-5-5`
```

**Codex** (`~/.codex/config.toml`; ChatGPT login refused):
```toml
model = "gpt-6-luna"
model_provider = "mubit"
[model_providers.mubit]
name = "Mubit"
base_url = "https://api.mubit.ai/openai/v1"
env_key = "MUBIT_API_KEY"
wire_api = "responses"
requires_openai_auth = false
```

**Gemini CLI:** `GOOGLE_GEMINI_BASE_URL=https://api.mubit.ai/gemini` with `GEMINI_API_KEY`. **Aider:** `OPENAI_API_BASE` with `--model openai/<id>`.

---

## What this means for the Roblox agent [INF]
1. **Give each job its own fixed system prompt, tools and model**, so each becomes a separate task: idea→spec, spec→Luau, and error→fix. Put the game idea, Studio errors and current code in the **user message**.
2. **Make corrections land in the same task.** Run the generate-and-fix loop under the same "write Luau" system prompt, with the error text in the user turn. Successful fixes then become kept examples of that task.
3. **Rate those calls Good/Bad in Requests** during the demo. That is the only documented feedback control.
4. **Use one session per game** (`metadata.session_id`, or Anthropic `metadata.user_id`) so the held-out test split is clean.
5. **Keep calls short** (under about 8k tokens, so each counts as one billed run) to avoid "examples too long to train on".
6. **Generate 25 or more varied examples early.** Training needs to be switched on for our workspace, and there is a daily training cap that resets at 00:00 UTC (01:00 London before the clocks change Sunday).
7. **Plan the demo around the console** (task → Training → `Passed` → Try models side by side), because adapters can't be called through the API. Remember the limit of 3 adapter starts per day.
8. **Questions for Mubit office hours:**
   - Is there a feedback, correction or rating API?
   - Do ratings affect which examples are kept?
   - Can an adapter be served through the API (model ID or header)?
   - How long does training take, and what is the hackathon's daily training limit?
   - Which open base model are adapters built on?