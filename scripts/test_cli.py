#!/usr/bin/env python3
"""Integration check against an installed App. Optional --window-id records it."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--cli', default='/Applications/iRecord.app/Contents/Helpers/irecord')
parser.add_argument('--window-id')
args = parser.parse_args()

help_result = subprocess.run([args.cli, '-h'], capture_output=True, text=True, timeout=10)
assert help_result.returncode == 0
assert 'Commands:' in help_result.stdout and 'irecord start' in help_result.stdout
assert '--crop-points' in help_result.stdout

def run(*words, code='ok', exit_code=None):
    p = subprocess.run([args.cli, *words, '--json'], capture_output=True, text=True, timeout=310)
    result = json.loads(p.stdout)
    assert result['code'] == code, result
    assert p.returncode == (exit_code if exit_code is not None else (0 if code == 'ok' else 1)), (p.returncode, result)
    return result

status = run('status')['values']
assert status['protocol_version'] == '1'
run('stop', code='invalid_arguments', exit_code=2)
run('unknown', code='invalid_arguments', exit_code=2)
run('pause', '--session-id', 'missing', code='session_mismatch')
print('PASS: -h menu, short commands, status, strict argument validation, invalid session')
if status['screen_permission'] != 'granted':
    run('ls', code='permission_required')
    print('PASS: permission_required; real recording not tested (screen permission required)')
    raise SystemExit(0 if not args.window_id else 1)
windows = run('ls')['windows']
if windows:
    needle = windows[0]['app']
    results = run('ls', '--search', needle)['windows']
    assert results and all(needle.casefold() in (w['app'] + w['title']).casefold() for w in results)
print('PASS: window listing/search')
if not args.window_id:
    print('SKIP: real recording; pass --window-id ID to opt in')
    raise SystemExit(0)
assert status['state'] == 'idle' and 'source_path' not in status, status
with tempfile.TemporaryDirectory(prefix='irecord-preview-test-') as directory:
    full = run('preview', '--window-id', args.window_id,
               '--output', str(Path(directory) / 'full.png'))['values']
    cropped = run('preview', '--window-id', args.window_id,
                  '--output', str(Path(directory) / 'page.png'),
                  '--crop-points', '10,0,0,0')['values']
    assert cropped['crop_mode'] == 'points'
    assert int(cropped['width']) == int(full['width'])
    assert int(cropped['height']) < int(full['height'])
    assert Path(full['output']).stat().st_size > 0
    assert Path(cropped['output']).stat().st_size > 0
    print('PASS: window PNG preview and point-based top crop')
session = run('start', '--window-id', args.window_id)['values']
sid = session['session_id']
assert session['state'] == 'recording'
run('start', '--window-id', args.window_id, code='already_recording')
run('stop', '--session-id', 'wrong', '--output', '/tmp/not-written.mp4', code='session_mismatch')
time.sleep(1)
assert run('pause', '--session-id', sid)['values']['state'] == 'paused'
assert run('resume', '--session-id', sid)['values']['state'] == 'recording'
time.sleep(1)
with tempfile.TemporaryDirectory(prefix='irecord-cli-test-') as directory:
    output = Path(directory) / 'recording.mp4'
    output.write_bytes(b'preserve existing file')
    run('stop', '--session-id', sid, '--output', str(output), code='output_exists')
    assert output.read_bytes() == b'preserve existing file'
    completed = run('stop', '--session-id', sid, '--output', str(output),
                    '--crop-points', '0,0,0,0', '--overwrite')['values']
    assert completed['state'] == 'completed'
    assert float(completed['duration_seconds']) > 0
    assert int(completed['width']) > 0 and int(completed['height']) > 0
    assert output.stat().st_size > 4096 and b'ftyp' in output.read_bytes()[:32]
    assert run('stop', '--session-id', sid, '--output', str(output))['values'] == completed
    print('PASS: start, duplicate prevention, session guard, pause/resume, overwrite protection, playable-container export, idempotent stop')
