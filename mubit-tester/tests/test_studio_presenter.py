"""Friendly results must preserve uncertainty and link feedback to actual actions."""
from mubit_tester.studio_presenter import check_choices, present_job


def job(operation='scenario', state='passed', result=None, **extra):
    return {'operation': operation, 'state': state, 'args': {'scenario': 'smoke.json'},
            'result': result or {}, **extra}


def test_skipped_check_never_says_worked():
    view = present_job(job(state='skipped', result={'skipped': True, 'passed': None,
                        'steps': [{'ok': True, 'detail': 'SKIP requires two players'}]}))
    assert view['status'] == 'Not checked'
    assert view['checks'][0]['optional']
    assert not view['checks'][0]['ok']


def test_optional_warning_not_presented_as_success():
    view = present_job(job(result={'name': 'smoke', 'warnings': ['agent missing'],
                        'steps': [{'ok': True, 'warning': True, 'label': 'every client agent ready'}]}))
    assert view['status'] == 'Some checks could not finish'
    assert not view['checks'][0]['ok']
    assert 'agent' not in view['checks'][0]['title']


def test_partial_result_cannot_hide_hard_failure():
    view = present_job(job(state='failed', result={'warnings': ['optional failed'],
                        'steps': [{'ok': False, 'label': 'everyone moved'}]}))
    assert view['status'] == 'A check did not pass'


def test_goal_failure_is_not_automatically_a_game_bug():
    view = present_job(job('playtest', 'failed', {'goal_met': False, 'bugs': [], 'summary': 'I got stuck.'}))
    assert view['status'] == 'Goal not reached'
    assert view['issues'] == []


def test_unknown_judgement_is_not_a_pass():
    view = present_job(job('playtest', 'failed', {'goal_met': None, 'errors': ['judge failed']}))
    assert view['status'] == 'Could not tell yet'


def test_correction_keeps_real_action_identity_without_user_entry():
    view = present_job(job('playtest', result={'run_id': 'saved-run', 'goal_met': True,
        'steps': [{'n': 4, 'player_name': 'Alex', 'action': {'action': 'move_to_instance', 'reason': 'Reach the door.'}}]}))
    assert view['actions'] == [{'step': 4, 'player': 'Alex', 'title': 'Walk to an object',
                               'reason': 'Reach the door.', 'can_correct': True}]
    assert view['run_id'] == 'saved-run'


def test_feedback_receipt_does_not_claim_training_completed():
    view = present_job(job('correct', result={'request_id': 'recorded'}))
    assert view['status'] == 'Feedback sent'
    assert 'does not' in view['summary']
    assert 'training has finished' in view['summary']


def test_issue_buttons_keep_each_bug_index():
    view = present_job(job('playtest', result={'run_id': 'saved-run', 'bugs': [
        {'title': 'Door stuck', 'evidence': 'did not open'}, {'title': 'No water', 'evidence': 'tank stayed empty'}]}))
    assert [item['index'] for item in view['issues']] == [0, 1]
    assert all(item['can_suggest'] for item in view['issues'])


def test_setup_and_fix_preview_are_different_from_game_success():
    assert present_job(job('install_harness'))['status'] == 'Ready to check'
    assert 'not been changed' in present_job(job('suggest_fix'))['summary']


def test_connection_errors_do_not_blame_the_game():
    view = present_job(job(state='failed', error='StudioError: a playtest is already running'))
    assert view['status'] == 'Could not finish'
    assert 'Stop it in Studio' in view['summary']


def test_choices_keep_files_for_execution_but_show_readable_names():
    result = check_choices([{'name': 'hydrant_refill', 'file': 'hydrant_refill.json'}])
    assert result[0]['title'] == 'Refill the water tank'
    assert result[0]['file'] == 'hydrant_refill.json'


def test_cancellation_does_not_inherit_a_success_status():
    view = present_job(job('playtest', 'cancelled', {'goal_met': True, 'summary': 'Goal happened.'}))
    assert view['status'] == 'Stopped'
    assert 'unchecked' in view['summary']
