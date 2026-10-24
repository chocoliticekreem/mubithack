"""Reuse the existing builder, keeping drafts separate until explicitly added to Studio."""
from __future__ import annotations

import asyncio
import json
import re
import shutil
import time
from pathlib import Path

from forge import levels, sync
from forge.loop import UI, new_game, run_game, correct
from forge.memory import RunStore, unique_slug
from forge.progress import Progress
from forge.studio import extract_json
from mubit_tester.harness import _long_bracket


DONE = {'director': 'Game design ready', 'designer': 'Game plan ready',
        'reflector': 'Saved what worked for the next build'}
DID = {'level_designer': 'Laid out the course:', 'coder': 'Wrote', 'fixer': 'Repaired', 'critic': 'Reviewed',
       'fun_critic': 'Checked how fun it is:'}
DOING = {'director': 'the game design', 'designer': 'the game plan', 'level_designer': 'the course',
         'coder': 'writing', 'fixer': 'repairing', 'critic': 'the review', 'fun_critic': 'the fun check',
         'reflector': 'saving lessons'}
PROGRESS_KEYS = ('pct', 'phase', 'step', 'items', 'eta_s')
POLL_S = 1.0
# a make_game job's % : build 0-70, install 70-75, improvement rounds 75-99, ready 100
BUILD_PCT, INSTALL_PCT, ROUNDS_PCT = 70, 75, 99
STANDARD_SCORE = 6
MAX_ROUNDS = 12  # safety cap only: rounds run until the game is up to standard
HARNESS = re.compile(r'Forge(Test|Probe|TestAgent|Telemetry)\b')
ROUND_EXPECTED_S = 240.0


class BuildProgress(UI):
    # forge reports a call when it finishes, so messages say what was done, not what is starting.
    def __init__(self, emit):
        super().__init__()
        self._emit = emit
        self.slug = None
        self.sent = set()

    def emit(self, message, ok=None):
        self.sent.add(message)
        if ok is None:
            self._emit(message)
        else:
            self._emit(message, ok)

    def print(self, line=''):
        pass

    def header(self, text):
        if found := re.match(r'forge new\s+(\S+)', text):
            self.slug = self.slug or found[1]
            self.emit('Planning your game…')
        elif found := re.match(r'build\s+(\d+) modules', text):
            self.emit(f'Writing {found[1]} game script{"" if found[1] == "1" else "s"}…')
        else:
            self.emit('Checking the draft code…')

    def call(self, role, label, ok, secs, rid, n_calls=1, err=''):
        label = label.removesuffix(' (cached)')
        if not ok:
            self.emit(f'Could not finish {DOING.get(role, role)} ({label}): {err.split(":")[0]}', False)
        elif role in DONE:
            self.emit(DONE[role])
        else:
            self.emit(f'{DID.get(role, "Finished")} {label}')

    def line(self, tag, label, ok=None, detail=''):
        if tag == 'check' and label.startswith('luau-compile'):
            if ok:
                self.emit('All game scripts compile')
            else:
                self.emit('Some game scripts do not compile yet', False)
        elif tag == 'done':
            self.emit('Finishing your first draft…')


class ProgressFeed:
    """Relays runs/<slug>/progress.json (written by forge) into job events and a progress summary."""

    def __init__(self, settings, ui, idea, emit, on_progress):
        self.settings, self.ui, self.idea = settings, ui, idea
        self.emit, self.on_progress = emit, on_progress
        self.started = time.time()
        self.seen, self.last = set(), None

    def slug(self):
        if self.ui.slug is None and self.settings.runs_dir.is_dir():
            # The "forge new <slug>" header names the run; if it ever changes, use the run made for this idea.
            for path in self.settings.runs_dir.iterdir():
                try:
                    if (path.stat().st_mtime >= self.started - 1
                            and json.loads((path / 'state.json').read_text()).get('idea') == self.idea):
                        self.ui.slug = path.name
                except (OSError, ValueError, AttributeError):
                    continue
        return self.ui.slug

    def poll(self):
        slug = self.slug()
        if not slug:
            return
        try:
            data = json.loads((RunStore(self.settings, slug).dir / 'progress.json').read_text())
        except (OSError, ValueError):
            return
        if not isinstance(data, dict):
            return
        for event in data.get('events') or []:
            if not isinstance(event, dict) or not isinstance(event.get('text'), str):
                continue
            key = (event.get('t'), event['text'])
            # forge's own event for a call often repeats the line BuildProgress already showed.
            if key in self.seen or event['text'] in self.ui.sent:
                continue
            self.seen.add(key)
            if event.get('ok') is None:
                self.emit(event['text'])
            else:
                self.emit(event['text'], bool(event['ok']))
        summary = {k: data.get(k) for k in PROGRESS_KEYS}
        if self.on_progress and summary != self.last:
            self.last = summary
            self.on_progress(summary)

    async def run(self):
        while True:
            await asyncio.sleep(POLL_S)
            self.poll()


def draft_store(settings, slug):
    if not isinstance(slug, str) or not re.fullmatch(r'[a-zA-Z0-9_-]+', slug):
        raise ValueError('Choose a saved game')
    store = RunStore(settings, slug)
    if not store.dir.resolve().is_relative_to(settings.runs_dir.resolve()) or not store.spec_path.is_file():
        raise ValueError('This game draft is no longer available')
    # Do not follow links when reading, copying or compiling a saved game.
    if any(path.is_symlink() for path in store.dir.rglob('*')):
        raise ValueError('Saved games cannot contain linked files')
    return store


def saved_games(settings):
    games = []
    for slug in RunStore.list_games(settings):
        try:
            store = draft_store(settings, slug)
            spec, state = store.load_spec(), store.load_state()
            games.append({'slug': slug, 'title': spec.get('title', slug), 'pitch': spec.get('pitch', ''),
                          'iterations': len(state.get('iterations', []))})
        except (ValueError, OSError, TypeError, AttributeError):
            continue
    return games


async def describe_draft(settings, slug):
    store = draft_store(settings, slug)
    spec = store.load_spec()
    failures = await asyncio.to_thread(sync.check, store.game_dir)
    missing = [m['path'] for m in spec.get('modules', []) if not (store.game_dir / m['path']).is_file()]
    if not spec.get('modules'):
        missing.append('The plan did not include any game scripts.')
    errors = [f'{path}: {message}' for path, message in failures] + [f'Missing: {p}' for p in missing]
    built, planned, gone = levels.course_status(spec)
    if gone:  # the promised content count (docs/GAME_PRODUCTION_GUIDE.md 8.3): a short course is not ready
        errors.append(f"Course has {built}/{planned} stages (zone{'s' if len(gone) > 1 else ''} "
                      f"{', '.join(map(str, gone))} failed)")
    state = store.load_state()
    return {'slug': slug, 'title': spec.get('title', 'Your new game'), 'pitch': spec.get('pitch', ''),
            'ready': not errors, 'errors': errors, 'files': [m['path'] for m in spec.get('modules', [])],
            'acceptance': spec.get('acceptance', []), 'runtime_checked': False,
            'project_slug': spec.get('mumake_project', slug),
            'iterations': [{k: item.get(k) for k in ('n', 'score', 'summary')} for item in state.get('iterations', [])],
            'calls': [{k: item.get(k) for k in ('role', 'request_id', 'latency_ms')} for item in store.read_calls()[-20:]]}


async def build_draft(settings, idea, emit, *, llm=None, on_progress=None):
    ui = BuildProgress(emit)
    feed = ProgressFeed(settings, ui, idea, emit, on_progress)
    watch = asyncio.create_task(feed.run())
    try:
        slug = await new_game(idea, iterations=1, use_studio=False, settings=settings, llm=llm, ui=ui)
    except asyncio.CancelledError:
        raise
    except Exception:
        feed.poll()
        raise
    finally:
        watch.cancel()
    feed.poll()
    return await describe_draft(settings, slug)


async def revise_draft(settings, slug, emit, *, path=None, note=None, llm=None):
    source = draft_store(settings, slug)
    spec = source.load_spec()
    if path is not None:
        modules = {m['path'] for m in spec.get('modules', [])}
        protected = set(spec.get('base_files', []))
        if path not in modules or path in protected:
            raise ValueError('Choose a generated game script to change')
        target = (source.game_dir / path).resolve()
        if not target.is_relative_to(source.game_dir.resolve()) or not target.is_file():
            raise ValueError('That game script is no longer available')
    revision = unique_slug(settings, slug + '-revision')
    destination = RunStore(settings, revision)
    # Revise a separate saved draft, including when it came from the agent plugin.
    # Cancellation and failed compilation never alter the original game or Studio.
    await asyncio.to_thread(shutil.copytree, source.dir, destination.dir)
    spec['slug'] = revision
    spec['mumake_project'] = spec.get('mumake_project', slug)
    destination.save_spec(spec)
    state = destination.load_state()
    state['slug'] = revision
    destination.save_state(state)
    if path is None:
        await run_game(revision, iterations=1, use_studio=False, settings=settings, llm=llm, ui=BuildProgress(emit))
    else:
        await correct(revision, path, note, use_studio=False, settings=settings, llm=llm, ui=BuildProgress(emit))
    result = await describe_draft(settings, revision)
    result['source_slug'] = slug
    return result


INSTALL_PRELUDE = r'''
local files=game:GetService("HttpService"):JSONDecode(__FILES__)
local function rootFor(service)
    if service=="StarterPlayerScripts" then
        local sp=game:GetService("StarterPlayer")
        return sp:FindFirstChildOfClass("StarterPlayerScripts") or sp:FindFirstChild("StarterPlayerScripts")
    end
    local ok,svc=pcall(game.GetService,game,service)
    return ok and svc or nil
end
-- the same lookups as the sync pull script, so this sees exactly the scripts it will write
local function target(f)
    local parent=rootFor(f.service)
    for _,name in f.dirs do
        if not parent then return nil end
        local found=nil
        for _,c in parent:GetChildren() do
            if c.Name==name and not c:IsA("LuaSourceContainer") then found=c break end
        end
        parent=found
    end
    if not parent then return nil end
    for _,c in parent:GetChildren() do
        if c.Name==f.name and c:IsA("LuaSourceContainer") then return c end
    end
    return nil
end
local function ours(inst)
    return inst:GetAttribute("MuMakeGenerated") or inst:GetAttribute("MubitTesterManaged")
end
'''
# MuMakePreflight: the sync overwrites same-named scripts and prunes ForgeManaged ones, so stop before
# either would touch a script MuMake did not add.
PREFLIGHT_LUAU = INSTALL_PRELUDE + r'''-- MuMakePreflight
local Http=game:GetService("HttpService")
for _,f in files do
    local t=target(f)
    if t and not ours(t) then
        return Http:JSONEncode({ok=false,error="Keep your existing script: "..f.path..". Use an empty local game for this draft."})
    end
end
for _,inst in game:GetService("CollectionService"):GetTagged("ForgeManaged") do
    if inst:IsA("LuaSourceContainer") and not ours(inst) then
        return Http:JSONEncode({ok=false,error="This place has scripts synced from another project ("..inst:GetFullName().."). Use an empty local game for this draft."})
    end
end
return Http:JSONEncode({ok=true})
'''
MARK_LUAU = INSTALL_PRELUDE + r'''-- MuMakeMark
local project=__PROJECT__
local n=0
for _,f in files do
    local t=target(f)
    if t then
        t:SetAttribute("MuMakeGenerated",true)
        t:SetAttribute("MuMakeProject",project)
        n+=1
    end
end
game:GetService("CoreGui"):SetAttribute("MuMakeLoadedGame",__SLUG__)
return n
'''


def _changed_count(out):
    found = re.search(r'changed: ([^;]*)', out)
    if not found or found[1].strip() == 'none':
        return 0
    return len([p for p in found[1].split(', ') if p.strip()])


async def install_draft(studio, settings, slug, *, place_id=0):
    """Put a draft into the bound Studio window through forge's chunked sync (Studio.sync): the manifest
    and small changed files travel inline, the rest is fetched from a local file server, so a big game never
    hits Studio's 200,000-character limit on one command. Returns {"files", "changed", "summary"}."""
    if place_id:
        raise ValueError("Add a draft to an unpublished local game, using the normal sync workflow for published games.")
    store = draft_store(settings, slug)
    root = store.game_dir.resolve()
    if not root.is_relative_to(settings.runs_dir.resolve()) or not root.is_dir():
        raise ValueError('This game draft is no longer available')
    if (await studio.state()).get('playing'):
        raise ValueError('A playtest is already running. Stop it in Studio first.')
    if await asyncio.to_thread(sync.check, root):
        raise ValueError('The draft code has errors. Keep it out of Studio until they are fixed.')
    entries = sync.manifest_entries(root)
    if not entries:
        raise ValueError('The draft contains no game scripts')
    files = _long_bracket(json.dumps([{k: e[k] for k in ('service', 'dirs', 'name', 'path')} for e in entries]))
    check = extract_json(await studio.execute_luau(PREFLIGHT_LUAU.replace('__FILES__', files, 1)))
    if not isinstance(check, dict) or not check.get('ok'):
        raise ValueError((check or {}).get('error') if isinstance(check, dict) else 'Studio did not check the draft')
    out = str(await studio.sync(root))
    if not out.startswith('OK'):
        raise ValueError(f'Studio could not add the draft: {out[:300]}')
    project = str(store.load_spec().get('mumake_project', slug))
    await studio.execute_luau(MARK_LUAU.replace('__FILES__', files, 1)
                              .replace('__PROJECT__', _long_bracket(project), 1)
                              .replace('__SLUG__', _long_bracket(slug), 1))
    return {'files': len(entries), 'changed': _changed_count(out), 'summary': out}


def build_share(on_progress):
    """The build's own 0-100 progress as the first BUILD_PCT of a make_game job."""
    if on_progress is None:
        return None

    def relay(summary):
        pct = summary.get('pct')
        # the build's ETA ends at the build, not at ready
        on_progress({**summary, 'eta_s': None,
                     'pct': int(pct * BUILD_PCT / 100) if isinstance(pct, (int, float)) else pct})
    return relay


def _n(count, word):
    return f'{count} {word}{"" if count == 1 else "s"}'


def standard(settings, slug, draft):
    """Is the latest iteration up to standard: critic score >= STANDARD_SCORE, 0 errors, playtest actually ran?"""
    its = RunStore(settings, slug).load_state().get('iterations') or []
    last = its[-1] if its else {}
    # Forge's own test harness is not the game: its errors never block a game from being ready
    errors = len([e for e in last.get('errors') or [] if not HARNESS.search(str(e))])
    score = last.get('score')
    out = {'ready': False, 'score': score, 'errors': errors, 'fixes': int(last.get('fixes') or 0),
           'round_line': last.get('round_line')}
    if not draft.get('ready'):
        out['reason'] = (draft.get('errors') or ['the draft is incomplete'])[0]
    elif not last:
        out['reason'] = 'no playtest has run yet'
    elif last.get('engine') not in {'headless', 'studio'} or 'playtest' in (last.get('failed_steps') or []):
        out['reason'] = 'the last round could not playtest the game'
    elif score is None:
        out['reason'] = 'the critic did not score the last round'
    elif errors:
        out['reason'] = f'{_n(errors, "error")} in the last playtest'
    elif score < STANDARD_SCORE:
        out['reason'] = f'score {score:g}/10, needs {STANDARD_SCORE}'
    else:
        out.update(ready=True, reason=f'score {score:g}/10 with 0 errors')
    return out


class RoundProgress(BuildProgress):
    """forge's lines during an improvement round; each one also becomes the round's progress step."""

    def __init__(self, emit, step):
        super().__init__(emit)
        self._step = step

    def emit(self, message, ok=None):
        super().emit(message, ok)
        self._step(message)

    def line(self, tag, label, ok=None, detail=''):
        if tag != 'done':  # "target reached" is not "finishing your first draft"
            super().line(tag, label, ok, detail)


async def finish_draft(settings, draft, emit, *, install, on_progress=None, llm=None, rounds=MAX_ROUNDS, show=None):
    """After the build: install into Studio, then up to `rounds` improvement rounds (headless playtest, critic,
    fix), re-installing after each so the window shows the game changing, until standard() is met.
    `install(slug)` puts the draft into Studio and returns {"files", "changed"}, or raises to say why not.
    `show(slug, keep)` launches the installed game in Studio and screenshots it (keep=True leaves it running)."""
    slug = draft['slug']
    store = RunStore(settings, slug)
    ui = BuildProgress(emit)
    ui.slug = slug
    feed = ProgressFeed(settings, ui, None, emit, on_progress)
    try:
        started = json.loads((store.dir / 'progress.json').read_text()).get('started')
    except (OSError, ValueError, AttributeError):
        started = None
    with Progress(store.dir / 'progress.json', slug, 'improve') as prog:
        prog.bands.update(install=(BUILD_PCT, INSTALL_PCT), improve=(INSTALL_PCT, ROUNDS_PCT))
        if isinstance(started, (int, float)):
            prog.state['started'] = started  # the ETA counts from the start of the build
        watch = asyncio.create_task(feed.run())
        try:
            return await _finish(settings, draft, emit, install, prog, feed, llm, rounds, show)
        finally:
            watch.cancel()


async def _finish(settings, draft, emit, install, prog, feed, llm, rounds, show=None):
    slug = draft['slug']
    studio = {'in': False, 'current': False, 'problem': None}

    def say(text, ok=None):
        prog.event(text, ok)
        feed.poll()

    async def put(done_text):
        try:
            res = await install(slug)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - not installing never stops the rounds
            studio.update(current=False, problem=str(error) or type(error).__name__)
            say(f"Not {'updated' if studio['in'] else 'installed'} in Studio: {studio['problem']}"[:300], False)
            return
        studio.update(**{'in': True, 'current': True, 'problem': None})
        say(done_text(res), True)
        await launch(False)

    async def launch(keep):
        if show is None or not studio['current']:
            return
        prog.step('Launching the game in Studio')
        feed.poll()
        try:
            shot = await show(slug, keep)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - a missing screenshot never stops the build
            say(f"Could not launch it in Studio: {error}"[:300], False)
            return
        if keep:
            say('Playing in Studio now: click the game view, then WASD to move and Space to jump', True)
        else:
            say('Launched in Studio' + (': new screenshot on the dashboard' if shot else ''), True)

    prog.phase('install', 'Installing in Studio')
    feed.poll()
    await put(lambda r: f"Installed in Studio: {_n(r['files'], 'script')}")
    status = standard(settings, slug, draft)
    prog.phase('improve', 'Checking the first playtest',
               expected_s=ROUND_EXPECTED_S * 3)  # unknown number of rounds: creep, never a fixed count
    feed.poll()
    done, failure = 0, None
    while not status['ready'] and done < rounds:
        prefix = f'Round {done + 1}'
        prog.step(f'{prefix}: playtesting, reviewing and fixing')
        feed.poll()
        try:
            await run_game(slug, iterations=1, use_studio=False, settings=settings, llm=llm,
                           ui=RoundProgress(emit, lambda m, p=prefix: prog.step(f'{p}: {m}')))
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - a failed round ends the rounds, not the job
            failure = f'{prefix} could not finish: {type(error).__name__}: {error}'[:300]
            say(failure, False)
            break
        done += 1
        draft = await describe_draft(settings, slug)
        status = standard(settings, slug, draft)
        score = f"{status['score']:g}/10" if status['score'] is not None else 'not scored'
        # forge.rounds.round_line: score and acceptance change, files fixed, what the fixer was taught
        if status['round_line']:
            text = f"{prefix}: {status['round_line']}; {_n(status['errors'], 'error')}"[:300]
        else:
            text = f"{prefix}: score {score}, {_n(status['errors'], 'error')}, fixed {_n(status['fixes'], 'problem')}"
        say(text, True if status['ready'] else None)
        prog.item_done()
        prog.step(f'{prefix}: updating Studio')
        feed.poll()
        await put(lambda r, p=prefix: f"{p} in Studio: {_n(r['changed'], 'script')} changed")
    after = f"after {_n(done, 'round')}" if done else 'on the first playtest'
    reason = status['reason'] if status['ready'] or not failure else failure
    ready = status['ready'] and studio['current']
    if status['ready'] and not studio['current']:
        reason = f"up to standard, but Studio does not have this version: {studio['problem']}"
    if ready:
        final = f"Ready: score {status['score']:g}/10 {after}"
    else:
        final = f"Not ready {after}: {reason}"
    if studio['current']:
        await launch(True)
    prog.done(final[:300], ready)
    feed.poll()
    result = dict(draft)
    result.update(in_studio=studio['in'], studio_current=studio['current'],
                  standard={'ready': ready, 'reason': reason, 'score': status['score'],
                            'errors': status['errors'], 'rounds': done})
    return result
