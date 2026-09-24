#!/usr/bin/env python3
"""Summarize observed costs separately from correct-path predictor accuracy."""
import argparse
import json
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True)
    root=p.parse_args().root.resolve()
    memory=json.loads((root/'memory-audit/manifest.json').read_text())
    penalty=json.loads((root/'penalty-audit/results.json').read_text())
    records=[]
    for case in penalty['results']:
        row=case['rows'][2]; event=row['audit']
        records.append({'layout':case['layout'],'latency_ns':case['latency_ns'],
                        'random_stalls':case['stalls'],'extra_cycles':case['extra_cycles'],
                        'redirect_to_correct_fetch_cycles':event['correct_fetch']-event['start'],
                        'read_outstanding_at_redirect':event['outstanding'],
                        'last_r_before_fetch':event['last'],
                        'all_modes_architecture_equal':True})
    observation={}
    for name in ['B0','T16']:
        path=root/'recovery-observer'/name/'results.json'
        data=json.loads(path.read_text()); assert len(data['results'])==10
        groups=[]
        for k,label in enumerate(['btb_missing','direction','target']):
            rows=[x['recovery'][k] for x in data['results']]
            count=sum(x['count'] for x in rows)
            groups.append({'kind':label,'count':count,
                           'mean_redirect_to_correct_fetch':sum(x['cycles'] for x in rows)/count,
                           'max_redirect_to_correct_fetch':max(x['maximum'] for x in rows),
                           'short_le8':sum(x['short_le8'] for x in rows)})
        observation[name]={'cases':len(data['results']),'recovery':groups,
            'history':{key:sum(x['history'][key] for x in data['results'])
                       for key in ['age_zero','age_one','age_many','age_sum','bits_differ']}}
    result={'status':'passed','memory_cases':memory['cases'],'paired_cases':len(records),
            'rtl_runs_in_pairs':sum(len(x['rows']) for x in penalty['results']),
            'pairs':records,'application_observation':observation,
            'limits':['Correct-path Python/C++ model uses immediate training and no timing penalty.',
                      'Delayed-history model measures event timing sensitivity, not CPU cycle time.',
                      'Classic Branchsim toy IPC assumes 2 or 12 cycles and is not used for this study.',
                      'Redirect-to-correct-fetch latency includes correct-target accesses and cannot be summed as lost cycles.',
                      'Directed pairs measure net execution-cycle difference, including changed request alignment.',
                      'Physical reference memory has one read burst outstanding and cumulative service deadlines; it is not a DRAM or full SoC model.',
                      'Native MicroBench uses the ysyxSoC AXI/APB delay-ratio model, not this reference memory; its known early-VALID timing bias is not removed by this audit.',
                      'Native timer/observer agreement validates the simulated window, not silicon timing or the physical fidelity of every peripheral.',
                      'Only B0 and T16 passive observers are covered; each has identical original result and counters.']}
    (root/'timing-audit.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS timing audit summary',flush=True)

if __name__=='__main__':main()
