#!/usr/bin/env python3
"""Small direction predictors. Correct-path screening is not a CPU timing model."""
import argparse
from collections import Counter, deque
import gzip
import json
import math
import subprocess
import tempfile
import hashlib
from pathlib import Path
from model_branch import decode
from model_direction import CounterTable, BiMode, LoopTable


def fold(value, bits, length):
    value &= (1 << length) - 1
    result = 0
    mask = (1 << bits) - 1
    while value:
        result ^= value & mask
        value >>= bits
    return result



class SmallTage:
    """Local three-bank TAGE variant: 4/8/16 history, 8-bit tags, 3-bit ctr, 1-bit u.

    Snapshots keep query history/provider/prediction/alternate. Training verifies
    current tag before updating a provider that may have been replaced meanwhile.
    Allocation chooses one eligible longer-history bank. Failed allocation ages
    only the corresponding longer-history entries. No speculative history here.
    """
    def __init__(self, entries=16, selective=False, protect_alternate=False):
        self.entries, self.selective = entries, selective
        self.protect_alternate = protect_alternate
        self.base = [1] * entries
        self.banks = [[None] * entries for _ in range(3)]
        self.history, self.history_bits = 0, 16
        self.stats = Counter()

    def addresses(self, pc, history):
        width = self.entries.bit_length() - 1
        return [(((pc >> 2) ^ fold(history, width, length)) & (self.entries-1),
                 ((pc >> 2) ^ (pc >> 10) ^ fold(history, 8, length)
                  ^ (fold(history, 7, length) << 1)) & 255) for length in (4, 8, 16)]

    def lookup(self, pc, history=None):
        history = self.history if history is None else history
        addresses = self.addresses(pc, history)
        prediction = self.base[(pc >> 2) & (self.entries-1)] >= 2
        alternate, provider, alternate_provider = prediction, 0, 0
        for bank, (index, tag) in enumerate(addresses):
            entry = self.banks[bank][index]
            if entry is not None and entry[0] == tag:
                alternate_provider = provider
                alternate, prediction, provider = prediction, entry[1] >= 4, bank+1
        return dict(pc=pc, history=history, provider=provider, taken=prediction, alternate=alternate, alternate_provider=alternate_provider)

    def train(self, query, taken, advance_history=True):
        pc, provider = query['pc'], query['provider']
        addresses = self.addresses(pc, query['history'])
        base_index = (pc >> 2) & (self.entries-1)
        base_prediction = self.base[base_index] >= 2
        self.base[base_index] = max(0, min(3, self.base[base_index] + (1 if taken else -1)))
        if provider:
            index, tag = addresses[provider-1]
            entry = self.banks[provider-1][index]
            if entry is not None and entry[0] == tag:
                entry[1] = max(0, min(7, entry[1] + (1 if taken else -1)))
                if query['taken'] != query['alternate']:
                    entry[2] = int(query['taken'] == taken)
            else:
                self.stats['stale_provider'] += 1
        if self.protect_alternate and query['alternate_provider'] and query['taken'] != taken and query['alternate'] == taken:
            bank = query['alternate_provider']-1
            index, tag = addresses[bank]
            entry = self.banks[bank][index]
            if entry is not None and entry[0] == tag:
                entry[2] = 1
        wrong = query['taken'] != taken
        if wrong and (not self.selective or base_prediction != taken):
            candidates = []
            for bank in range(provider, 3):
                index, tag = addresses[bank]
                entry = self.banks[bank][index]
                if entry is None or entry[2] == 0:
                    candidates.append(bank)
            if candidates:
                bank = candidates[0]
                index, tag = addresses[bank]
                self.banks[bank][index] = [tag, 4 if taken else 3, 0]
                self.stats['allocations'] += 1
            else:
                for bank in range(provider, 3):
                    index, _ = addresses[bank]
                    self.banks[bank][index][2] = 0
                self.stats['allocation_blocked'] += 1
        if advance_history:
            self.history = ((self.history << 1) | taken) & 65535

    def predict(self, pc, target):
        self.pending = self.lookup(pc)
        return self.pending['taken']

    def update(self, pc, target, taken):
        self.train(self.pending, taken)

    def state_bits(self):
        return self.entries * (2 + 3*(8+3+1+1)) + 16


class LocalHistory:
    def __init__(self, entries=32, history_bits=4):
        self.histories = [0] * entries
        self.table = [1] * (1 << history_bits)
        self.bits = history_bits

    def predict(self, pc, target):
        self.row = (pc >> 2) & (len(self.histories)-1)
        self.index = self.histories[self.row]
        return self.table[self.index] >= 2

    def update(self, pc, target, taken):
        self.table[self.index] = max(0, min(3, self.table[self.index] + (1 if taken else -1)))
        self.histories[self.row] = ((self.index << 1) | taken) & ((1 << self.bits)-1)

    def state_bits(self):
        return len(self.histories)*self.bits + 2*len(self.table)


class Perceptron:
    def __init__(self, entries=8, history_bits=16):
        self.weights = [[0]*(history_bits+1) for _ in range(entries)]
        self.history, self.bits = 0, history_bits
        self.threshold = int(1.93*history_bits+14)

    def predict(self, pc, target):
        self.index = (pc >> 2) & (len(self.weights)-1)
        self.inputs = [1]+[1 if self.history & (1 << bit) else -1 for bit in range(self.bits)]
        self.score = sum(w*x for w,x in zip(self.weights[self.index], self.inputs))
        return self.score >= 0

    def update(self, pc, target, taken):
        if (self.score >= 0) != taken or abs(self.score) <= self.threshold:
            sign = 1 if taken else -1
            self.weights[self.index] = [max(-128,min(127,w+sign*x)) for w,x in zip(self.weights[self.index],self.inputs)]
        self.history = ((self.history << 1) | taken) & ((1 << self.bits)-1)

    def state_bits(self):
        return len(self.weights)*(self.bits+1)*8+self.bits


def configurations():
    configs = {}
    for entries in [16,64,128,256,512,1024]:
        configs[f'bimodal{entries}'] = lambda n=entries: CounterTable(n)
        bits = int(math.log2(entries))
        configs[f'gshare{entries}'] = lambda n=entries,h=bits: CounterTable(n,h)
    for entries in [8,16,32]:
        configs[f'tage{entries}'] = lambda n=entries: SmallTage(n)
        configs[f'tage{entries}-alt'] = lambda n=entries: SmallTage(n,protect_alternate=True)
        configs[f'tage{entries}-selective'] = lambda n=entries: SmallTage(n,True)
    for entries in [16,32,64]:
        for history in [4,8]:
            configs[f'local{entries}-h{history}'] = lambda n=entries,h=history: LocalHistory(n,h)
    for entries in [4,8,16]:
        configs[f'perceptron{entries}'] = lambda n=entries: Perceptron(n)
    for entries in [4,8]:
        configs[f'loop{entries}'] = lambda n=entries: LoopTable(n)
    return configs


def read_trace(path):
    opener = gzip.open if path.suffix == '.gz' else open
    branches, instructions = [], 0
    with opener(path, 'rt') as stream:
        for line in stream:
            pc, insn, nxt, cycle = line.split(',')
            instructions += 1
            record = decode(int(pc,16),int(insn,16),int(nxt,16))
            if record and record[1] == 0:
                branches.append(record)
    return branches, instructions


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--engine',choices=['cpp','python'],default='cpp')
    a=p.parse_args();root=a.root.resolve();rows={}
    cases=json.loads((root/'images/manifest.json').read_text())['cases']
    digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    provenance={'python_sha256':digest(Path(__file__)), 'trace_sha256':{}}
    if a.engine=='cpp':
        binary=root/'direction_model'
        source=Path(__file__).resolve().parents[1]/'tools/branch_explore/direction_model.cpp'
        command=['g++','-std=c++17','-O2',str(source),'-o',str(binary)]
        compiler=subprocess.check_output(['g++','--version'],text=True).splitlines()[0]
        build={'source_sha256':digest(source),'command':command,'compiler':compiler}
        record=root/'direction-model-build.json'
        old=json.loads(record.read_text()) if record.exists() else {}
        if not binary.exists() or any(old.get(k)!=v for k,v in build.items()) or old.get('binary_sha256')!=digest(binary):
            subprocess.run(command,check=True)
            record.write_text(json.dumps(dict(build,binary_sha256=digest(binary)),indent=2)+'\n')
        provenance.update(json.loads(record.read_text()))
    for case in cases:
        if case['held']: continue
        path=root/'rtl/dev-common/B0'/(case['name']+'.trace')
        if not path.exists(): path=path.with_suffix('.trace.gz')
        provenance['trace_sha256'][str(path)]=digest(path)
        results={}
        if a.engine=='cpp':
            with tempfile.NamedTemporaryFile(dir=root,suffix='.trace') as temporary:
                trace=path
                if path.suffix=='.gz':
                    temporary.write(gzip.open(path,'rb').read());temporary.flush();trace=Path(temporary.name)
                output=subprocess.check_output([str(binary),str(trace)],text=True)
            for line in output.splitlines():
                name,bits,errors,false_taken,branches,instructions=line.split(',')
                results[name]=dict(errors=int(errors),false_taken=int(false_taken),branches=int(branches),state_bits=int(bits),mpki=int(errors)*1000/int(instructions))
            factories={}
        else:
            records,instructions=read_trace(path);factories=configurations()
        for name,factory in factories.items():
            predictor=factory();counts=Counter()
            for pc,_,taken,target,_,_ in records:
                prediction=predictor.predict(pc,target)
                counts['errors'] += prediction != taken
                counts['false_taken'] += prediction and not taken
                counts['branches'] += 1
                predictor.update(pc,target,taken)
            results[name]=dict(counts,state_bits=predictor.state_bits(),mpki=counts['errors']*1000/instructions)
        rows[case['name']]=results
        print('MODEL',case['name'],flush=True)
    summary={name:dict(error_ratio_gm=math.exp(sum(math.log(row[name]['errors']/row['bimodal16']['errors']) for row in rows.values())/len(rows)),state_bits=next(iter(rows.values()))[name]['state_bits']) for name in configurations()}
    (root/'model.json').write_text(json.dumps(dict(engine=a.engine,provenance=provenance,scope='correct-path immediate-training conditional accuracy; excludes BTB, wrong paths, pipeline and checkpoint costs; not IPC',cases=rows,summary=summary),indent=2)+'\n')
    for name,result in sorted(summary.items(),key=lambda x:x[1]['error_ratio_gm']): print(name,result,flush=True)


if __name__=='__main__': main()
