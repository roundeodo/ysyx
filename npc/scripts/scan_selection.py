#!/usr/bin/env python3
"""Reproduce the broad geometry/policy screen from frozen development traces."""
import argparse
import itertools
import json
from pathlib import Path

from explore_frontend import NPC, run, sha

POLICIES = ['fifo', 'lru', 'plru', 'random', 'lip', 'bip', 'srrip', 'insert3',
            'brrip', 'drrip', 'burst_rrip', 'burst_pc', 'burst_history', 'opt']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--traces', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--extra-trace', type=Path, help='Optional functional MicroBench trace')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    source = NPC / 'tools/icache_explore/model.cpp'
    run(['g++', '-std=c++17', '-O2', source, '-o', out / 'model'], out / 'build.log')
    grid = []
    for capacity, ways, line in itertools.product([256, 512, 1024, 2048, 4096, 8192, 16384],
                                                  [1, 2, 4, 8], [16, 32, 64]):
        if ways * line > capacity:
            continue
        for policy in (['fifo', 'opt'] if ways == 1 else POLICIES):
            grid.append(f'{capacity},{ways},{line},{policy}\n')
    (out / 'grid.csv').write_text(''.join(grid))
    traces = sorted(args.traces.resolve().glob('*-dev-*.trace'))
    assert len(traces) == 6, 'Expect exactly six frozen development traces'
    if args.extra_trace:
        traces.append(args.extra_trace.resolve())
    manifest = {'source_sha256': sha(source), 'binary_sha256': sha(out / 'model'),
                'grid_sha256': sha(out / 'grid.csv'), 'configurations': len(grid), 'traces': []}
    for trace in traces:
        command = [out / 'model', trace, out / 'grid.csv', out / (trace.name + '.csv')]
        run(command, out / (trace.name + '.log'))
        manifest['traces'].append({'path': str(trace), 'sha256': sha(trace),
                                   'command': list(map(str, command))})
        (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(trace.name, 'PASS', flush=True)


if __name__ == '__main__':
    main()
