#!/usr/bin/env python3
"""Install the native plugin and start its localhost companion. Never opens Studio."""
from __future__ import annotations
import argparse
import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import URLError, HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT), str(ROOT / 'mubit-tester')]
from mubit_tester.studio_service import DEFAULT_PORT, load_token


def plugin_source(port, token):
    experience = (ROOT / 'studio-plugin/Experience.luau').read_text()
    source = 'local Experience = (function()\n' + experience + '\nend)()\n'
    return source + (ROOT / 'studio-plugin/MuMake.plugin.luau').read_text().replace(
        '__MUBIT_SERVICE_URL__', f'http://127.0.0.1:{port}').replace('__MUBIT_PAIRING_TOKEN__', token)


def health(port, token):
    req = Request(f'http://127.0.0.1:{port}/health', headers={'Authorization': f'Bearer {token}'})
    try:
        with urlopen(req, timeout=2) as response:
            return json.load(response)
    except HTTPError as error:
        raise SystemExit(f'Port {port} is occupied by an unpaired service ({error.code}); use --port')
    except (URLError, TimeoutError):
        return None


async def load_existing(source, studio_id):
    from forge.studio import Studio
    async with Studio(call_timeout=45) as studio:
        for _ in range(12):
            items = await studio.list_studios()
            if items:
                break
            await asyncio.sleep(1)
        if studio_id:
            matches = [s for s in items if s['id'] == studio_id]
        else:
            matches = items if len(items) == 1 else []
        if len(matches) != 1:
            raise SystemExit('Installed on disk. Select one existing MCP window using --studio-id; no Studio was opened.')
        studio.studio_id = matches[0]['id']
        state = await studio.state()
        if state.get('playing'):
            raise SystemExit('Installed on disk. Finish your current playtest before live-loading the plugin.')
        await studio.execute_luau('local plugin = PluginManager():CreatePlugin()\n' + source + '\nreturn "MuMake loaded"')
        print(f'Loaded into existing Studio {studio.studio_id}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=DEFAULT_PORT)
    parser.add_argument('--plugins-dir', type=Path, default=Path.home() / 'Documents/Roblox/Plugins')
    parser.add_argument('--load-existing', action='store_true', help='Load now through MCP without opening or restarting Studio')
    parser.add_argument('--studio-id')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('port must be between 1024 and 65535')
    store = ROOT / 'runs/studio-plugin'
    token = load_token(store)
    if not health(args.port, token):
        python = ROOT / '.venv/bin/python'
        if not python.is_file():
            raise SystemExit('Install the repository Python dependencies into .venv first')
        with (store / 'companion.log').open('ab') as log:
            process = subprocess.Popen([str(python), '-m', 'mubit_tester.studio_service', '--port', str(args.port)],
                cwd=ROOT, env={**os.environ, 'FORGE_PROJECT_DIR': str(ROOT)},
                stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
        (store / 'companion.pid').write_text(str(process.pid))
        for _ in range(40):
            if health(args.port, token):
                break
            if process.poll() is not None:
                raise SystemExit(f'Companion failed to start. See {store / "companion.log"}')
            time.sleep(.25)
        else:
            raise SystemExit(f'Companion did not become ready. See {store / "companion.log"}')
    source = plugin_source(args.port, token)
    args.plugins_dir.mkdir(parents=True, exist_ok=True)
    path = args.plugins_dir / 'MuMake.lua'
    # The installed file contains a local pairing token, never the Mubit API key.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as file:
        file.write(source)
    path.chmod(0o600)
    legacy = args.plugins_dir / 'MubitTester.lua'
    if legacy.is_file() and 'CoreGui:FindFirstChild("MubitTesterControl")' in legacy.read_text():
        legacy.unlink()
    print(f'Installed {path}')
    print(f'Companion ready on 127.0.0.1:{args.port}')
    if args.load_existing:
        asyncio.run(load_existing(source, args.studio_id))


if __name__ == '__main__':
    main()
