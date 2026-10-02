#!/usr/bin/env python3
"""Pair measured runs by software and memory contract; never infer candidate cycles."""
import argparse
import collections
import gzip
import hashlib
import json
import math
import re
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'
DOCS = NPC / 'docs/research/branch-v3'
PPA = {'S-victim':'S-victim','SE0-victim':'SE0-victim','E0-victim':'E0-victim',
       'NER0-victim':'NER0-victim','NSLER-victim':'NSLER-victim',
       'H2E-victim':'H2E-victim','R0-victim':'R0-victim','NSmallER-victim':'NSmallER-victim',
       'N0-victim':'N0-victim','NL-victim':'NL-victim','NS-victim':'NS-victim',
       'NSL-parallel':'NSL-parallel','NSL-provider':'NSL-provider',
       'NSL-victim':'NSL-victim','B0-victim':'B0-victim',
       'NL':'NL','NS':'NS','NSL':'NSL','SE0':'SE0','B0off': 'B0-final-off', 'B0-current': 'B0-latest', 'B32': 'B32',
       'H2-narrow': 'H2-narrow-v2', 'H2E-narrow': 'H2E-narrow', 'S': 'S',
       'E0': 'E0', 'N0-widthfix': 'N0', 'N0E': 'N0E', 'R0-held': 'R0-held',
       'NSmallER': 'NSmallER-held', 'NSmall': 'NSmall', 'B64': 'B64',
       'G64': 'G64', 'G256': 'G256', 'NBase128': 'NBase128'}


def means(details):
    groups = collections.defaultdict(list)
    for item in details:
        groups[item['family']].append(item['time_ratio'])
    family = {key: math.exp(sum(map(math.log, values))/len(values)) for key, values in groups.items()}
    return {'family_geomeans': family,
            'paired_geomean': math.exp(sum(map(math.log, family.values()))/len(family)),
            'worst_ratio': max(item['time_ratio'] for item in details)}


def read_records():
    records = []
    for index in sorted((ROOT/'rtl').glob('*/index.json')):
        for item in json.loads(index.read_text()):
            log = index.parent/(item['name']+'.log')
            text = log.read_text()
            assert 'PASS proxy' in text
            assert hashlib.sha256(log.read_bytes()).hexdigest() == item['log_sha256']
            values = {}
            for line in text.splitlines():
                if line.startswith(('RESULT ', 'COUNTERS ', 'DETAIL ')):
                    values.update({k: int(v) for k, v in re.findall(r'(\w+)=(\d+)(?=\s|$)', line)
                                   if k not in ('digest', 'checksum')})
            plus = dict(word[1:].split('=', 1) for word in item['command'][1:] if word.startswith('+'))
            image, mhz = Path(plus['image']), int(plus['cpu_mhz'])
            records.append({'run': index.parent.name, 'case': item['name'],
                            'executable': Path(item['command'][0]).parents[1].name,
                            'family': item['name'].split('-')[0].removesuffix('_stream'),
                            'dataset': image.parents[1].name, 'image': str(image.relative_to(NPC)),
                            'mhz': mhz, 'latency_ns': int(plus['latency_ns']),
                            'random_stalls': int(plus['random_stalls']), 'seed': int(plus['seed']),
                            'seconds': values['cycles']/(mhz*1e6), 'ipc': values['retired']/values['cycles'],
                            **values, 'log': str(log.relative_to(NPC)),
                            'log_sha256': item['log_sha256'],
                            'binary_sha256': item.get('binary_sha256'),
                            'binary_binding': 'run index' if 'binary_sha256' in item else
                                              'early index lacks executable hash; source/build manifest retained'})
    return records


def identity(record):
    return tuple(record[key] for key in ('image', 'latency_ns', 'random_stalls', 'seed'))


def compare(records, baseline, same_frequency):
    groups = collections.defaultdict(list)
    for record in records:
        groups[record['run']].append(record)
    comparisons = []
    for name, items in groups.items():
        details = []
        for record in items:
            choices = [b for b in baseline.get(identity(record), [])
                       if b['mhz'] == (record['mhz'] if same_frequency else 720)]
            if not choices:
                continue
            assert len({(b['cycles'], b['retired']) for b in choices}) == 1, choices
            ref = choices[0]
            assert record['retired'] == ref['retired'], (name, record['case'], 'different workload')
            details.append({'case': record['case'], 'family': record['family'], 'baseline_run': ref['run'],
                            'time_ratio': record['seconds']/ref['seconds'],
                            'i_beat_ratio': record['i_beats']/max(1, ref['i_beats']),
                            'query_ratio': record['queries']/max(1, ref['queries'])})
        if details:
            comparisons.append({'run': name, 'dataset': items[0]['dataset'], 'mhz': items[0]['mhz'],
                                'cases': len(details), 'complete': len(details) == len(items),
                                **means(details), 'details': details})
    return comparisons


def retired_equivalence():
    cache_path = ROOT/'path-hashes.json'
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}

    def digest(path):
        actual = path if path.exists() else Path(str(path)+'.gz')
        stamp = f'{actual.stat().st_size}:{actual.stat().st_mtime_ns}'
        key = str(path.relative_to(NPC))
        if key in cache and cache[key]['stamp'] == stamp:
            return cache[key]['result']
        value, count = hashlib.sha256(), 0
        opener = gzip.open if actual.suffix == '.gz' else open
        with opener(actual, 'rt') as stream:
            for line in stream:
                value.update((','.join(line.strip().split(',')[:3])+'\n').encode())
                count += 1
        result = [count, value.hexdigest()]
        cache[key] = {'stamp': stamp, 'result': result}
        return result

    names = ['B0off', 'B0-final-off', 'B0-latest', 'B0-opportunity', 'S', 'B32', 'B64', 'G64', 'G256',
             'H2-narrow-v2', 'H2E-narrow', 'E0', 'T16-valid', 'T16B32-valid', 'N0', 'NL', 'NS', 'NSL',
             'N0E', 'N0B32', 'NSmall', 'NBase128', 'N0-spec-final', 'NL-spec', 'NS-spec', 'NSL-spec',
             'R0-held', 'ER0-held', 'NER0-held', 'NSmallER-held']
    results = []
    for name in names:
        folder = ROOT/'rtl'/name
        if not (folder/'index.json').exists():
            continue
        for item in json.loads((folder/'index.json').read_text()):
            got = digest(folder/(item['name']+'.trace'))
            ref = digest(ROOT/'rtl/B0'/(item['name']+'.trace'))
            assert got == ref, (name, item['name'], 'retired path mismatch')
            results.append({'candidate': name, 'case': item['name'], 'retired': got[0], 'path_sha256': got[1]})
    cache_path.write_text(json.dumps(cache, indent=2)+'\n')
    (DOCS/'retired-equivalence.json').write_text(json.dumps(results, indent=2)+'\n')
    return len(results)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--paths', action='store_true')
    args = parser.parse_args()
    records = read_records()
    baseline = collections.defaultdict(list)
    for record in records:
        if record['executable'].startswith('B0'):
            baseline[identity(record)].append(record)
    qualified = {}
    for name, binary in PPA.items():
        file = ROOT/'ppa'/name/'qualified.json'
        if file.with_name('qualified-fine.json').exists():
            file = file.with_name('qualified-fine.json')
        if file.exists():
            qualified[name] = {**json.loads(file.read_text()), 'executable': binary}
    result = {'status': 'development/validation unless explicitly named final; no implicit acceptance',
              'scope': 'ns service rerun at each frequency; equal families and equal inputs within families',
              'records': records, 'same_frequency': compare(records, baseline, True),
              'versus_baseline_720MHz': compare(records, baseline, False), 'qualified_ppa': qualified}
    (DOCS/'measurements.json').write_text(json.dumps(result, indent=2)+'\n')
    print('PASS measured records', len(records), 'PPA', len(qualified), flush=True)
    if args.paths:
        print('PASS retired-path comparisons', retired_equivalence(), flush=True)


if __name__ == '__main__':
    main()
