#!/usr/bin/env python3
"""Independent threshold oracle for measured STA grid search and seed hints."""
from sta_report import qualify_grid

count=0
for cutoff in range(180,841,10):
    for estimate in [None,150,365,719.8,830]:
        results={}
        def measure(mhz):
            if str(mhz) not in results:
                results[str(mhz)]={'passed':mhz<=cutoff,'groups':{
                    'data_max':{'fmax_mhz':cutoff},'data_min':{'slack_ns':.1},
                    'gating_min':{'slack_ns':.1}}}
            return results[str(mhz)]['passed']
        expected=max([f for f in range(200,801,20) if f<=cutoff],default=None)
        actual=qualify_grid(measure,results,estimate)
        assert actual==expected,(cutoff,estimate,actual,expected)
        if actual is not None:
            assert results[str(actual)]['passed']
            if actual<800:assert not results[str(actual+20)]['passed']
        count+=1
# A measured hold failure requires exhaustive qualification, not setup inference.
results={}
def hold_probe(mhz):
    passed=mhz<=700
    results[str(mhz)]={'passed':passed,'groups':{
        'data_max':{'fmax_mhz':780},'data_min':{'slack_ns':.1 if passed else -.1},
        'gating_min':{'slack_ns':.1}}}
    return passed
assert qualify_grid(hold_probe,results,780)==700
assert all(str(f) in results for f in range(700,801,20))
print('PASS',count,'threshold cases and hold-failure scan')
