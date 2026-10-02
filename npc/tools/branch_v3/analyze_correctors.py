#!/usr/bin/env python3
"""Account for SC/loop overrides using real query snapshots and resolution events.

Replay only the small selector state not present in the saved context. Assert
every final prediction against RTL, including wrong-path queries. This is an
attribution check, not a replacement for the existing full-state cosimulation.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path

from summarize import read_records
from trace_io import open_text

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC / 'result/branch-v3'
DOCS = NPC / 'docs/research/branch-v3'
CONFIGURATIONS = {'TAGE': ('N0', False, False), 'TAGE_Loop': ('NL', False, True),
                  'TAGE_SC': ('NS', True, False), 'TAGE_SC_Loop': ('NSL', True, True)}


def unpack_context(value):
    # Default base32, 3x16 tagged, tag8, history3/7/16; SV packed struct LSB first.
    widths = [('prediction', 1), ('loop_index', 2), ('sum', 9), ('sc_indices', 12),
              ('tage', 1), ('weak', 1), ('raw', 1), ('alt', 1), ('provider', 3),
              ('base_index', 5), ('tags', 24), ('indices', 12), ('epoch', 16),
              ('pc', 32), ('history_before', 16)]
    result = {}
    for name, width in widths:
        result[name] = value & ((1 << width) - 1)
        value >>= width
    assert value == 0
    if result['sum'] & 256:
        result['sum'] -= 512
    if result['provider'] & 4:
        result['provider'] -= 8
    return result


def analyze(path, sc_enabled, loop_enabled):
    saved, roi, committed = {}, {}, set()
    threshold, loops = 8, [None] * 4
    counts, thresholds = collections.Counter(), collections.Counter()
    sites = collections.defaultdict(collections.Counter)
    patterns = collections.defaultdict(collections.Counter)
    digest = hashlib.sha256()
    queries = 0
    with open_text(path) as stream:
        for line in stream:
            digest.update(line.encode())
            row = line.rstrip().split(',')
            if row[0] == 'Q':
                identity, pc = int(row[1]), int(row[3], 16)
                context = unpack_context(int(row[11], 16))
                assert context['pc'] == pc and context['epoch'] == 0
                assert context['history_before'] == 0, 'This diagnostic requires resolved history'
                tage = bool(context['tage'])
                sc = context['sum'] >= 0 if sc_enabled and abs(context['sum']) >= threshold else tage
                entry = loops[context['loop_index']]
                valid = bool(loop_enabled and entry and entry['pc'] == pc and
                             entry['confidence'] == 3 and entry['trip'] > 0)
                final = (not entry['direction'] if entry['current'] + 1 == entry['trip']
                         else entry['direction']) if valid else sc
                assert final == bool(context['prediction']) == bool(int(row[5])), (path, identity, 'selector mismatch')
                saved[identity] = {**context, 'sc': sc, 'final': final, 'threshold': threshold,
                                   'loop_valid': valid, 'loop_at_query': dict(entry) if valid else None}
                queries += 1
            elif row[0] == 'F':
                identity, kind, taken = int(row[1]), int(row[5]), bool(int(row[6]))
                context = saved[identity]
                assert context['pc'] == int(row[3], 16)
                if kind != 1:
                    continue
                if sc_enabled:
                    sc_sign = context['sum'] >= 0
                    if sc_sign != bool(context['tage']):
                        threshold = min(31, threshold + 1) if sc_sign != taken else max(1, threshold - 1)
                if loop_enabled:
                    index, pc = context['loop_index'], context['pc']
                    entry = loops[index]
                    # Diagnostic only: state immediately before this branch trains.
                    # It may include older iterations that were unresolved at query.
                    context['loop_at_resolve'] = dict(entry) if entry else None
                    if entry is None or entry['pc'] != pc:
                        loops[index] = {'pc': pc, 'current': 1, 'trip': 0,
                                        'confidence': 0, 'direction': taken}
                    elif taken == entry['direction']:
                        if entry['current'] == 255:
                            entry.update(current=0, trip=0, confidence=0)
                        else:
                            entry['current'] += 1
                    else:
                        trip = entry['current'] + 1
                        entry['confidence'] = min(3, entry['confidence'] + 1) if trip == entry['trip'] else 0
                        entry['trip'], entry['current'] = trip & 255, 0
            elif row[0] == 'R' and int(row[5]) == 1:
                identity, taken = int(row[1]), bool(int(row[6]))
                context = saved[identity]
                assert context['pc'] == int(row[3], 16)
                tage, sc, final = bool(context['tage']), context['sc'], context['final']
                metrics = {'conditional': 1, 'internal_tage_errors': tage != taken,
                           'final_direction_errors': final != taken,
                           'sc_helpful': sc != tage and sc == taken,
                           'sc_harmful': sc != tage and sc != taken,
                           'loop_helpful': final != sc and final == taken,
                           'loop_harmful': final != sc and final != taken,
                           'loop_valid': context['loop_valid']}
                old, now = context['loop_at_query'], context.get('loop_at_resolve')
                if old and now and all(old[k] == now[k] for k in ('pc', 'trip', 'direction', 'confidence')):
                    newer_prediction = not now['direction'] if now['current'] + 1 == now['trip'] else now['direction']
                    metrics['loop_wrong_fixed_by_resolved_iteration'] = final != taken and newer_prediction == taken
                    metrics['loop_correct_broken_by_resolved_iteration'] = final == taken and newer_prediction != taken
                    metrics['loop_iteration_changed_before_resolve'] = old['current'] != now['current']
                counts.update(metrics)
                sites[hex(context['pc'])].update(metrics)
                thresholds[str(context['threshold'])] += 1
                if sc != tage:
                    provider = ('base' if context['provider'] < 0 else
                                'weak_tagged' if context['weak'] else 'nonweak_tagged')
                    patterns[provider]['helpful' if sc == taken else 'harmful'] += 1
                roi[identity] = (context['pc'], int(row[4], 16), taken)
            elif row[0] == 'C':
                committed.add(int(row[1]))
                assert int(row[4], 16) & 0x707f != 0x100f, 'FENCE.I invalidation is not replayed here'
    assert set(roi).issubset(committed)
    assert counts['final_direction_errors'] == (counts['internal_tage_errors'] - counts['sc_helpful'] +
           counts['sc_harmful'] - counts['loop_helpful'] + counts['loop_harmful'])
    sequence_hash = hashlib.sha256(json.dumps(list(roi.values())).encode()).hexdigest()
    return {'counts': dict(counts), 'query_predictions_checked': queries,
            'conditional_sequence_sha256': sequence_hash,
            'query_threshold_histogram': dict(thresholds), 'sc_provider_classes': dict(patterns),
            'sites': dict(sites), 'event_sha256_uncompressed': digest.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configurations', nargs='+', choices=list(CONFIGURATIONS), default=list(CONFIGURATIONS))
    parser.add_argument('--output', type=Path, default=DOCS / 'corrector-attribution.json')
    args = parser.parse_args()
    measured = read_records()
    previous = json.loads((DOCS / 'attribution.json').read_text())
    baseline = {}
    records, aggregates = [], {}
    for configuration in args.configurations:
        prefix, sc, loop = CONFIGURATIONS[configuration]
        selected = [r for r in measured if r['run'] in
                    (prefix + '-victim-dev', prefix + '-victim-stream-dev-700')]
        assert len(selected) == 14
        total, histogram = collections.Counter(), collections.Counter()
        classes = collections.defaultdict(collections.Counter)
        for row in selected:
            path = ROOT / 'rtl' / row['run'] / (row['case'] + '.events')
            result = analyze(path, sc, loop)
            key = (row['dataset'], row['case'])
            if key not in baseline:
                baseline[key] = result['conditional_sequence_sha256']
            assert baseline[key] == result['conditional_sequence_sha256']
            known = [r for r in previous['records'] if r['configuration'] == configuration and
                     r['dataset'] == row['dataset'] and r['case'] == row['case']]
            if known:
                assert result['counts']['final_direction_errors'] == known[0]['counts']['raw_direction_errors']
            total.update(result['counts'])
            histogram.update(result['query_threshold_histogram'])
            for name, values in result['sc_provider_classes'].items():
                classes[name].update(values)
            records.append({'configuration': configuration, 'case': row['case'], 'dataset': row['dataset'],
                            'run': row['run'], 'binary_sha256': row['binary_sha256'], **result})
        aggregates[configuration] = {'counts': dict(total), 'query_threshold_histogram': dict(histogram),
                                     'sc_provider_classes': dict(classes)}
        print('PASS corrector attribution', configuration, dict(total), flush=True)
    output = {'scope': '14 development windows at 700MHz; default geometry, resolved history, no early redirect',
              'limits': ['Selector replay must match every recorded RTL query; full-state correctness uses separate cosimulation.',
                         'Same-run internal TAGE is distinct from standalone TAGE, since prediction changes pipeline timing.',
                         'Alias and feature limitations are structural hypotheses; this accounting does not isolate their causes.',
                         'No FENCE.I or nonzero epoch allowed in these application streams.'],
              'aggregates': aggregates, 'records': records}
    args.output.write_text(json.dumps(output, indent=2) + '\n')


if __name__ == '__main__':
    main()
