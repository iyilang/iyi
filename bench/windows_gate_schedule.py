#!/usr/bin/env python3
"""Check Windows workflow placement and exercise its extracted shell gates."""
import concurrent.futures
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

from identity_floor import line_allowed

import yaml

ROOT = Path(__file__).resolve().parent.parent
BASE = json.loads((ROOT / 'bench/fixtures/windows_gate_schedule.before.json').read_text())
WORKFLOW = ROOT / '.github/workflows/iyi.yml'
DEST = 'windows-gates'
COLLECTOR = "The collector's gates, on Windows"
SOCKET = 'Sockets, on Windows'
GUARD = "${{ !cancelled() && steps.compiler.outcome == 'success' }}"
GATES = ['arena_exercise.sh', 'root_exercise.sh', 'mark_exercise.sh',
         'sweep_exercise.sh', 'collect_trigger.sh', 'thread_exercise.sh',
         'parallel_mark.sh', 'concurrent_mark.sh']


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def inventory(steps):
    return [{k: step[k] for k in ('run', 'shell', 'env') if k in step}
            for step in steps if 'run' in step]


def named(steps, name):
    matches = [s for s in steps if s.get('name') == name]
    require(len(matches) == 1, f'{name}: expected exactly one, found {len(matches)}')
    return matches[0]


def check(workflow):
    jobs = workflow['jobs']
    dest_job = jobs[DEST]
    dest = dest_job['steps']
    require(dest_job.get('runs-on') == 'windows-2025', f'{DEST}: runner')
    require('needs' not in dest_job, f'{DEST}: serial needs')
    require(dest_job.get('timeout-minutes') == 90, f'{DEST}: timeout')
    require(not dest_job.get('continue-on-error'), f'{DEST}: continue-on-error')
    for step in dest:
        require('continue-on-error' not in step, f'{DEST}: continue-on-error')
        uses = step.get('uses', '').lower()
        require('cache' not in uses and 'artifact' not in uses, f'{DEST}: shared artifact/cache')
    for name, job in jobs.items():
        if name != DEST:
            require(not any(s.get('name') in (COLLECTOR, SOCKET) for s in job.get('steps', [])), f'{name}: moved gates outside {DEST}')
    collector = named(dest, COLLECTOR)
    socket = named(dest, SOCKET)
    require(dest[-2:] == [collector, socket], 'collector/socket placement or order')
    for step in (collector, socket):
        require(step.get('if') == GUARD, f"{step['name']}: guard")
        require(set(step) == {'name', 'if', 'shell', 'run'}, f"{step['name']}: unexpected fields")
    builds = [s for s in dest if s.get('id') == 'compiler']
    require(len(builds) == 1 and builds[0].get('name') == "Build the fork's compiler, then `iyi`", 'compiler build id')
    foundation = [name for name, job in jobs.items() if str(job.get('runs-on', '')).startswith('windows') for s in job.get('steps', []) if 'bash bench/std_exercise.sh' in s.get('run', '')]
    require(foundation == ['windows-std-core'], 'foundation runs once, in windows-std-core')
    expected = copy.deepcopy(BASE)
    old_donor = expected['windows-std']['steps']
    old_dest = expected[DEST]['steps']
    old_collector = named(old_donor, COLLECTOR)
    old_socket = named(old_donor, SOCKET)
    require(inventory([collector]) == inventory([old_collector]), 'collector command inventory or bound')
    require(inventory([socket]) == inventory([old_socket]), 'socket command inventory')
    old_donor.remove(old_collector)
    old_donor.remove(old_socket)
    for step in (old_collector, old_socket):
        step['if'] = GUARD
        old_dest.append(step)
    named(old_dest, "Build the fork's compiler, then `iyi`")['id'] = 'compiler'
    expected[DEST]['name'] = 'The language and collector gates, on Windows'
    require(dest_job == expected[DEST], f'{DEST}: job or step inventory')
    needs = jobs['release']['needs']
    require('windows-std' in needs and DEST in needs, 'release needs windows-std and windows-gates')
    return collector['run'], socket['run']


def run_fixture(bodies, failure=None, label='fixture'):
    collector, socket = bodies
    with tempfile.TemporaryDirectory(prefix='iyi-windows-gates-') as temp:
        root = Path(temp)
        bench = root / 'bench'
        bench.mkdir()
        (root / 'identity').write_text(label)
        (bench / 'bounded_gate.sh').write_text('test "$1" = 15 || exit 99\nshift\nbash "$1"\n')
        fake = ('test "$(cat identity)" = "$FIXTURE_ID" || exit 98\n'
                'echo "$FIXTURE_ID:$0" >> calls\n'
                'if [ "${FAIL_GATE:-}" = "${0##*/}" ]; then exit "${FAIL_STATUS}"; fi\n')
        for gate in GATES + ['socket_exercise.sh']:
            (bench / gate).write_text(fake)
        env = dict(os.environ, FIXTURE_ID=label)
        if failure:
            env.update(FAIL_GATE=failure[0], FAIL_STATUS=str(failure[1]))
        results = [subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', body], cwd=root,
                                  env=env, capture_output=True, text=True) for body in (collector, socket)]
        calls = (root / 'calls').read_text().splitlines()
        expected = [f'{label}:bench/{g}' for g in GATES + ['socket_exercise.sh']]
        require(calls == expected, f'{label}: gate order, bounds or isolation: {calls}')
        expected_collector = 1 if failure and failure[0] in GATES else 0
        expected_socket = 1 if failure and failure[0] == 'socket_exercise.sh' else 0
        require((results[0].returncode != 0) == bool(expected_collector), f'{label}: collector failure status')
        require((results[1].returncode != 0) == bool(expected_socket), f'{label}: socket failure status')


def negative_controls(original):
    def moved(w): return w['jobs']['windows-gates']['steps'][-2]
    def remove(w): moved(w)['run'] = moved(w)['run'].replace('bench/root_exercise.sh ', '')
    def duplicate(w): moved(w)['run'] = moved(w)['run'].replace('bench/root_exercise.sh ', 'bench/root_exercise.sh bench/root_exercise.sh ')
    def bound(w): moved(w)['run'] = moved(w)['run'].replace('bounded_gate.sh 15', 'bounded_gate.sh')
    def runner(w): w['jobs']['windows-gates']['runs-on'] = 'ubuntu-24.04'
    def release(w): w['jobs']['release']['needs'].remove('windows-std')
    def guard(w): moved(w)['if'] = 'always()'
    def masked(w): moved(w)['continue-on-error'] = True
    def serial(w): w['jobs']['windows-gates']['needs'] = 'windows-std'
    for name, mutation in [('omission', remove), ('duplication', duplicate), ('bound', bound),
                           ('runner', runner), ('release dependency', release), ('guard', guard),
                           ('failure masking', masked), ('serialization', serial)]:
        changed = copy.deepcopy(original)
        mutation(changed)
        try:
            check(changed)
        except (AssertionError, StopIteration) as error:
            print(f'negative control {name}: rejected ({error})')
        else:
            raise AssertionError(f'negative control {name}: accepted')


def main():
    fixture = 'bench/fixtures/windows_gate_schedule.before.json'
    bootstrap = 'crys' + 'tal'
    version = f'          "{bootstrap}": "1.21.0"'
    require(line_allowed(version, fixture) is not None, 'bootstrap fixture line rejected')
    require(line_allowed(version, 'bench/other.json') is None, 'bootstrap exception escaped fixture')
    require(line_allowed(f'          "{bootstrap}": "2.0.0"', fixture) is None, 'bootstrap version exception widened')
    workflow = yaml.safe_load(WORKFLOW.read_text())
    bodies = check(workflow)
    print('retained collector gates:', ', '.join(GATES))
    print('retained socket gate: socket_exercise.sh; foundation: std_exercise.sh')
    for status in (1, 124):
        run_fixture(bodies, ('sweep_exercise.sh', status), f'collector-{status}')
    run_fixture(bodies, ('socket_exercise.sh', 1), 'socket-failure')
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(run_fixture, bodies, None, label) for label in ('isolation-a', 'isolation-b')]
        for future in futures:
            future.result()
    print('collector exit 1/124, socket failure, and concurrent fixture isolation: passed')
    negative_controls(workflow)
    print('Windows gate scheduling contract: passed')


if __name__ == '__main__':
    main()
