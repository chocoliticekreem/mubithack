"""Reuse the existing builder, keeping drafts separate until explicitly added to Studio."""
from __future__ import annotations

import asyncio
import json
import re
import shutil
from pathlib import Path

from forge import sync
from forge.loop import UI, new_game, run_game, correct
from forge.memory import RunStore, unique_slug
from mubit_tester.harness import _long_bracket


class BuildProgress(UI):
    def __init__(self, emit):
        super().__init__()
        self.emit = emit

    def print(self, line=''):
        pass

    def header(self, text):
        self.emit('Planning your game…' if 'forge new' in text else 'Checking the draft code…')

    def call(self, role, label, ok, secs, rid, n_calls=1, err=''):
        stages = {'designer': 'The game plan is ready.', 'coder': 'Writing your game code…',
                  'fixer': 'Repairing a problem in the draft…', 'critic': 'Reviewing the game code…',
                  'reflector': 'Saving what worked for the next build…'}
        self.emit(stages.get(role, 'Working on your game…') if ok else 'Part of the build could not finish.')

    def line(self, tag, label, ok=None, detail=''):
        if tag == 'done':
            self.emit('Finishing your first draft…')


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
    state = store.load_state()
    return {'slug': slug, 'title': spec.get('title', 'Your new game'), 'pitch': spec.get('pitch', ''),
            'ready': not errors, 'errors': errors, 'files': [m['path'] for m in spec.get('modules', [])],
            'acceptance': spec.get('acceptance', []), 'runtime_checked': False,
            'project_slug': spec.get('mumake_project', slug),
            'iterations': [{k: item.get(k) for k in ('n', 'score', 'summary')} for item in state.get('iterations', [])],
            'calls': [{k: item.get(k) for k in ('role', 'request_id', 'latency_ms')} for item in store.read_calls()[-20:]]}


async def build_draft(settings, idea, emit, *, llm=None):
    slug = await new_game(idea, iterations=1, use_studio=False, settings=settings,
                          llm=llm, ui=BuildProgress(emit))
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


def draft_install_code(settings, slug):
    root = draft_store(settings, slug).game_dir.resolve()
    if not root.is_relative_to(settings.runs_dir.resolve()) or not root.is_dir():
        raise ValueError('This game draft is no longer available')
    # Use the same path mapping as the existing file-to-Studio sync tool.
    entries = sync._load().manifest_entries(root)
    if not entries:
        raise ValueError('The draft contains no game scripts')
    for entry in entries:
        path = (root / entry['path']).resolve()
        if not path.is_relative_to(root):
            raise ValueError('A draft script points outside its game folder')
        entry['source'] = path.read_text()
    payload = _long_bracket(json.dumps(entries))
    project = _long_bracket(str(draft_store(settings, slug).load_spec().get('mumake_project', slug)))
    return f'''
local files=game:GetService("HttpService"):JSONDecode({payload})
local project={project}
local editor=game:GetService("ScriptEditorService")
local history=game:GetService("ChangeHistoryService")
local function rootFor(f)
    if f.service=="StarterPlayerScripts" then return game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts") end
    return game:GetService(f.service)
end
-- Check every destination before changing any scripts or folders.
for _,f in files do
    local parent=rootFor(f)
    for _,name in f.dirs do
        parent=parent and parent:FindFirstChild(name)
        if parent and not parent:IsA("Folder") then error("Existing object blocks draft folder: "..f.path) end
    end
    local target=parent and parent:FindFirstChild(f.name)
    if target then
        if target.ClassName~=f.class then error("Existing object blocks draft script: "..f.path) end
        local ownDraft=target:GetAttribute("MuMakeGenerated") and target:GetAttribute("MuMakeProject")==project
        if not ownDraft and editor:GetEditorSource(target)~=f.source then
            error("Keep your existing script: "..f.path..". Use an empty local game for this draft.")
        end
    end
end
local recording
if not history:IsRecordingInProgress() then
    recording=history:TryBeginRecording("MuMakeDraft","Add MuMake game draft")
    if not recording then error("Finish the current Studio operation and try again") end
end
local ok,err=pcall(function()
    for _,f in files do
        local parent=rootFor(f)
        for _,name in f.dirs do
            local child=parent:FindFirstChild(name)
            if not child then child=Instance.new("Folder") child.Name=name child.Parent=parent end
            parent=child
        end
        local target=parent:FindFirstChild(f.name)
        local created=target==nil
        if not target then target=Instance.new(f.class) target.Name=f.name target.Parent=parent end
        if editor:GetEditorSource(target)~=f.source then editor:UpdateSourceAsync(target,function() return f.source end) end
        -- Identical existing scripts stay under their original ownership.
        if created then
            target:SetAttribute("MuMakeGenerated",true)
            target:SetAttribute("MuMakeProject",project)
        end
    end
end)
if recording then history:FinishRecording(recording,ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel) end
if not ok then error(err) end
game:GetService("CoreGui"):SetAttribute("MuMakeLoadedGame",{_long_bracket(slug)})
return "Added "..#files.." draft scripts. Press Play in Studio to try the game."
'''
