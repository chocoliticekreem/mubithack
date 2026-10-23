"""Plain-language views of native jobs. Presentation never changes test evidence."""
from __future__ import annotations

CHECK_NAMES = {
    'smoke.json': ('Quick check', 'Appear in the game, walk a short distance, and check for game errors.'),
    'hydrant_refill.json': ('Refill the water tank', 'Try a hydrant in the firefighter game.'),
    'heat_overheat.json': ('Get too close to a fire', 'Check heat and recovery in the firefighter game.'),
    'hose_tether.json': ('Move with the hose', 'Check the hose connection in the firefighter game.'),
    'coop_panda.json': ('Rescue together', 'A firefighter check that needs more than one player.'),
    'friendly_fire_blame.json': ('Check teammate damage', 'A firefighter check that needs more than one player.'),
    'lobby_countdown.json': ('Start a round together', 'Check the firefighter lobby countdown.'),
    'squad_parallel.json': ('Play in separate teams', 'A firefighter check that needs more than one player.'),
}
SMOKE_LABELS = {
    'players spawned': 'You appear in the game with health',
    'walk 10 studs': 'Your character can walk',
    'everyone moved': 'Your character reaches a new spot',
    'no probe errors': 'No game errors were recorded',
    'every client agent ready': 'MuMake can control the character',
    'lobby snapshot': 'Read the waiting area',
    'instances snapshot': 'Read active rounds',
}
ACTION_NAMES = {
    'move_to': 'Walk to a spot', 'walk_to': 'Walk to a spot',
    'move_to_instance': 'Walk to an object', 'interact': 'Use an object',
    'key': 'Press a key', 'spray': 'Spray water', 'use': 'Use the equipped item',
    'equip': 'Equip an item', 'wait': 'Wait', 'done': 'Finish playing',
}


def check_choices(scenarios):
    return [{'file': item['file'], 'title': CHECK_NAMES.get(item['file'], (item['name'].replace('_', ' '), ''))[0],
             'description': CHECK_NAMES.get(item['file'], ('', item.get('description', '')))[1]}
            for item in scenarios if not item.get('error')]


def title_for(job):
    operation = job['operation']
    if operation == 'scenario':
        return CHECK_NAMES.get(job.get('args', {}).get('scenario', 'smoke.json'), ('Saved game check', ''))[0]
    if operation == 'playtest':
        return str(job.get('args', {}).get('goal', 'Try a goal'))
    if operation == 'make_game':
        return str((job.get('result') or {}).get('title') or 'Making your game')
    if operation == 'load_game':
        return str((job.get('result') or {}).get('title') or 'Add draft to Studio')
    return {'explore': 'Look for problems', 'inspect': 'Look at the current game',
            'install_harness': 'Prepare this game', 'suggest_fix': 'Get a fix idea',
            'correct': 'Send feedback'}.get(operation, 'Game check')


def present_job(job):
    result = job.get('result') or {}
    state, operation = job['state'], job['operation']
    status = {'queued': 'Waiting to start', 'running': 'In progress', 'cancelling': 'Stopping',
              'cancelled': 'Stopped', 'skipped': 'Not checked', 'interrupted': 'Interrupted',
              'passed': 'Finished', 'failed': 'Needs a look'}.get(state, 'In progress')
    summary = ''
    checks, issues, actions = [], [], []
    if operation == 'make_game':
        if state == 'passed' and result.get('ready'):
            status = 'Your first draft is ready'
            summary = str(result.get('pitch') or '') + '\nReview it below, then add it to Studio to try it. It has not been played yet.'
        elif state == 'failed':
            status, summary = 'The draft needs more work', 'The code is saved, but some parts could not finish. It has not been added to Studio.'
    elif operation == 'load_game' and state == 'passed':
        status, summary = 'Added to Studio', 'Press Play in Studio to try your draft. You can undo adding its scripts. It has not been playtested by MuMake yet.'
    elif operation == 'scenario':
        for item in result.get('steps', []):
            title = SMOKE_LABELS.get(item.get('label'), (item.get('label') or 'Game check').replace('_', ' '))
            unchecked = bool(item.get('warning') or str(item.get('detail', '')).startswith(('SKIP', 'unmet, skipping')))
            checks.append({'title': title, 'ok': item.get('ok') is True and not unchecked,
                           'optional': unchecked})
        if result.get('skipped') or state == 'skipped':
            status, summary = 'Not checked', 'This check could not run with the players or game features available.'
        elif state == 'failed' and result:
            status, summary = 'A check did not pass', 'See what happened below, then try again after a change.'
        elif result.get('partial') or result.get('warnings'):
            status, summary = 'Some checks could not finish', 'Open the details to see which parts were unavailable.'
        elif state == 'passed':
            status, summary = 'These checks worked', 'Your character appeared, moved, and the game recorded no errors.' if result.get('name') == 'smoke' else 'The selected checks passed during this playthrough.'
    elif operation in {'playtest', 'explore'}:
        summary = str(result.get('summary') or '')
        if result:
            if result.get('goal_met') is True:
                status = 'Goal reached' if not result.get('bugs') else 'Goal reached, with possible problems'
            elif result.get('goal_met') is False:
                status = 'Goal not reached'
            else:
                status = 'Could not tell yet'
        for index, bug in enumerate(result.get('bugs') or []):
            issues.append({'index': index, 'title': str(bug.get('title', 'Possible problem')),
                           'evidence': str(bug.get('evidence', '')), 'can_suggest': bool(result.get('run_id'))})
        for item in result.get('steps') or []:
            action = item.get('action') or {}
            if not action:
                continue
            actions.append({'step': item.get('n'), 'player': item.get('player_name') or str(item.get('player', '')),
                            'title': ACTION_NAMES.get(action.get('action'), 'Try an action'),
                            'reason': str(action.get('reason') or ''), 'can_correct': bool(result.get('run_id'))})
    elif operation == 'install_harness' and state == 'passed':
        status, summary = 'Ready to check', 'MuMake can now try this game. Go back to Check game to begin.'
    elif operation == 'suggest_fix' and state == 'passed':
        status, summary = 'Fix idea ready', 'This is a suggestion for your code. Your game has not been changed.'
    elif operation == 'correct' and state == 'passed':
        status, summary = 'Feedback sent', 'Your note was sent through Mubit as a new example. This does not change the game or confirm that training has finished.'
    elif operation == 'inspect' and state == 'passed':
        summary = 'Read the players and game errors from the current playthrough.'
    errors = result.get('errors') or []
    probe_errors = (result.get('probe') or {}).get('errors') or []
    for error in probe_errors:
        issues.append({'title': 'The game recorded an error', 'evidence': str(error.get('message', error)) if isinstance(error, dict) else str(error), 'can_suggest': False})
    if errors:
        summary = (summary + '\n' if summary else '') + 'MuMake also had trouble completing part of this check. See technical details.'
    if job.get('error'):
        status = 'Could not finish'
        raw = job['error']
        if 'already running' in raw:
            summary = 'A game is already playing. Stop it in Studio, then try again.'
        elif 'no longer connected' in raw or 'identity changed' in raw.lower():
            summary = 'Reconnect this Studio window in Settings, then try again.'
        elif 'MUBIT_API_KEY' in raw:
            summary = 'AI play needs to be connected in Settings. Quick check works without it.'
        elif 'ForgeTest' in raw or 'ForgeProbe' in raw:
            summary = 'MuMake could not read this game. Open Settings and prepare it for checking.'
        else:
            summary = 'MuMake could not finish trying your game. Try again, or open technical details to find out why.'
    if state == 'cancelled':
        status = 'Stopped'
        summary = 'You stopped this build. Any partial draft stays saved and has not been added to Studio.' if operation == 'make_game' else 'You stopped this check. Anything it did not finish is still unchecked.'
    if state == 'interrupted':
        status = 'Interrupted'
        summary = 'MuMake restarted before this finished. Check Studio has stopped playing before trying again.'
    return {'title': title_for(job), 'status': status, 'summary': summary, 'checks': checks,
            'issues': issues, 'actions': actions, 'can_repeat': operation in {'scenario', 'playtest', 'explore'},
            'run_id': result.get('run_id')}
