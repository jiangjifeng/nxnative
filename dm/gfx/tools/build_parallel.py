#!/usr/bin/env python3
"""Run the unchanged shader compiler in separate processes, with pixels before paired vertices."""
import argparse
import builtins
import datetime
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def worker():
    summary, package, cache, *keys = sys.argv[2:]
    original_open = builtins.open

    def report_open(path, *args, **kwargs):
        mode = args[0] if args else kwargs.get('mode', 'r')
        if isinstance(path, (str, bytes, os.PathLike)) and os.path.basename(os.fsdecode(path)) == '_b_build.json' and 'w' in mode:
            path = summary
        return original_open(path, *args, **kwargs)

    # Each worker writes its own report; every shader key belongs to one worker.
    # Run the compiler at its real source path so its fingerprints are unchanged.
    builtins.open = report_open
    source = HERE / 'dmsh_build.py'
    sys.argv = [str(source), package, cache, *keys]
    runpy.run_path(str(source), run_name='__main__')


def build(args):
    import dmsh_chain
    package, destination = args.package.expanduser().resolve(), args.cache.expanduser().resolve()
    if package.is_relative_to(REPO) or destination.is_relative_to(REPO):
        raise ValueError('Keep shader packages and build caches outside the source repository.')
    errors = dmsh_chain.check_tools()
    if errors:
        raise ValueError('\n'.join(errors))
    chain = dmsh_chain.version()
    if f'"{chain}"' not in Path(dmsh_chain.HEADER).read_text():
        raise ValueError('Generate the profile header with dmsh_chain.py --header first.')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    working = destination.with_name(destination.name + '.fresh-' + stamp) if args.fresh else destination
    working.mkdir(parents=True, exist_ok=not args.fresh)
    output = working / ('b-' + chain)
    reports = working / 'parallel_logs' / stamp
    reports.mkdir(parents=True)
    env = os.environ.copy()
    env.update(J=str(args.threads), DMSH_CAS=str(working / 'cas'))
    rows = [line.split('\t') for line in dmsh_chain.GAME.table('shader_map.tsv').read_text().splitlines() if line and not line.startswith(('#', 'package'))]
    keys = {row[3] for row in rows}
    paired = {line.split()[0] for line in dmsh_chain.GAME.table('shader_pairs.tsv').read_text().splitlines() if line and not line.startswith('#')}
    results = {}
    started = time.monotonic()

    def phase(name, selected):
        running = []
        print(f'{name}: {len(selected)} shaders, {args.jobs} processes x {args.threads} threads', flush=True)
        try:
            for index in range(args.jobs):
                subset = selected[index::args.jobs]
                if not subset:
                    continue
                summary = reports / f'{name}-{index}.json'
                log = summary.with_suffix('.log')
                stream = log.open('w')
                command = [sys.executable, str(Path(__file__).resolve()), '--worker', str(summary), str(package), str(working), *subset]
                process = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                running.append((process, stream, summary, log))
            while any(process.poll() is None for process, _, _, _ in running):
                time.sleep(10)
                completed = sum(path.name.endswith('_b.json') for path in output.iterdir()) if output.exists() else 0
                print(f'{time.strftime("%H:%M:%S")} {name}: {completed}/{len(keys)} libraries', flush=True)
            for process, stream, summary, log in running:
                stream.close()
                if process.returncode or not summary.is_file():
                    raise RuntimeError(f'Compiler failed; see {log}')
                for record in json.loads(summary.read_text()):
                    results[record['key']] = record
            failed = [record for record in results.values() if record['st'] != 'ok']
            if failed:
                raise RuntimeError(f'Shader failures: {failed}')
        finally:
            for process, stream, _, _ in running:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                stream.close()

    # The original vs_pad pass reads the paired pixel MSL. Finish those files
    # before any process starts compiling paired vertices.
    phase('pixel-compute', sorted(keys - paired))
    phase('vertex', sorted(keys & paired))
    if set(results) != keys:
        raise RuntimeError('The partition reports do not cover the complete shader map.')
    for key in keys:
        for suffix in ('_b.json', '_b.metallib', '_b.metal'):
            if not (output / (key + suffix)).is_file():
                raise RuntimeError(f'Missing shader output: {key}{suffix}')
        if json.loads((output / (key + '_b.json')).read_text())['chain'] != chain:
            raise RuntimeError(f'Wrong translation chain: {key}')
    (output / '_b_build.json').write_text(json.dumps(list(results.values()), ensure_ascii=False))
    report = dict(chain=chain, shaders=len(keys), ok=len(keys), fresh=args.fresh, processes=args.jobs,
                  threads_per_process=args.threads, elapsed_seconds=round(time.monotonic() - started, 1))
    (working / '_parallel_build.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.fresh:
        backup = destination.with_name(destination.name + '.before-' + stamp)
        if destination.exists():
            destination.rename(backup)
        try:
            working.rename(destination)
        except Exception:
            if backup.exists():
                backup.rename(destination)
            raise
    print(f'Complete: {len(keys)} shaders; {report["elapsed_seconds"]} s; {destination}', flush=True)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        worker()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('cache', type=Path)
    parser.add_argument('--jobs', type=int, default=min(12, os.cpu_count() or 1))
    parser.add_argument('--threads', type=int, default=2, help='Compiler threads in each process')
    parser.add_argument('--fresh', action='store_true', help='Build into an empty cache, validate, then replace the previous cache')
    args = parser.parse_args()
    if args.jobs < 1 or args.threads < 1:
        parser.error('--jobs and --threads must be positive')
    try:
        build(args)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Shader build failed: {error}\n')


if __name__ == '__main__':
    main()
