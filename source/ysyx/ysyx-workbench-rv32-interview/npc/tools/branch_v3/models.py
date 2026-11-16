"""Readable M0 references. lookup never receives outcomes; snapshots own training indices.

These are scaled design experiments, NOT the unmodified Seznec author predictor.
No method reports CPU time. Metadata availability is an explicit caller contract.
"""
from dataclasses import dataclass


def sat(value, up, lo=0, hi=3):
    return max(lo, min(hi, value + (1 if up else -1)))


def fold(history, length, width):
    value = history & ((1 << length) - 1)
    result = 0
    while value:
        result ^= value & ((1 << width) - 1)
        value >>= width
    return result


@dataclass(frozen=True)
class Query:
    pc: int
    static: bool
    metadata_valid: bool
    index: int
    counter: int
    dynamic: bool
    prediction: bool
    tag: int
    epoch: int


class Hybrid:
    """H1 tagged cold initialization; H2 weak fallback; H3 agree; H4 chooser.

    Static bias is supplied only when metadata is available. H3 table learns
    agreement only on metadata-valid queries; it never trains agreement using
    a taken target. H1 uses full PC tags as an explicit, costly simple control.
    """
    def __init__(self, policy='bimodal', entries=16, history_bits=4):
        assert entries >= 2 and entries & (entries - 1) == 0
        self.policy, self.entries, self.history_bits = policy, entries, history_bits
        self.history = 0
        self.epoch = 0
        self.counters = [1] * entries
        self.chooser = [1] * entries
        self.tags = [None] * entries

    @property
    def bits(self):
        return self.entries * (2 + (33 if self.policy == 'h1' else 0) +
                               (2 if self.policy == 'h4' else 0)) + (self.history_bits if self.policy == 'gshare' else 0)

    def lookup(self, pc, static=False, metadata_valid=True):
        index = (pc >> 2) & (self.entries - 1)
        if self.policy == 'gshare':
            width = self.entries.bit_length() - 1
            assert self.history_bits <= width
            index ^= self.history << (width - self.history_bits)
        counter = self.counters[index]
        dynamic = bool(counter >> 1)
        prediction = dynamic
        if self.policy == 'nt':
            prediction = False
        elif self.policy == 'static':
            prediction = static if metadata_valid else False
        elif self.policy == 'h1' and metadata_valid and self.tags[index] != pc:
            prediction = static
        elif self.policy == 'h2' and metadata_valid and counter in (1, 2):
            prediction = static
        elif self.policy == 'h3':
            prediction = (dynamic == static) if metadata_valid else False
        elif self.policy == 'h4' and metadata_valid and self.chooser[index] < 2:
            prediction = static
        return Query(pc, static, metadata_valid, index, counter, dynamic, prediction, pc, self.epoch)

    def train(self, q, taken):
        if q.epoch != self.epoch:
            return
        index = q.index
        if self.policy == 'h1' and self.tags[index] != q.pc:
            if not q.metadata_valid:
                return
            self.tags[index] = q.pc
            self.counters[index] = sat(2 if q.static else 1, taken)
        elif self.policy == 'h3':
            if q.metadata_valid:
                self.counters[index] = sat(self.counters[index], taken == q.static)
        elif self.policy not in ('static', 'nt'):
            self.counters[index] = sat(self.counters[index], taken)
        if self.policy == 'h4' and q.metadata_valid and q.static != q.dynamic:
            self.chooser[index] = sat(self.chooser[index], q.dynamic == taken)
        self.history = ((self.history << 1) | int(taken)) & ((1 << self.history_bits) - 1)

    def invalidate(self):
        self.epoch += 1
        self.tags = [None] * self.entries
        self.history = 0

    def state(self):
        return (tuple(self.counters), tuple(self.chooser), tuple(self.tags), self.history, self.epoch)


class ScaledTage:
    """Explicit scaled TAGE + optional PC/global SC + regular-trip loop.

    Independent base and tagged capacities; signed 3-bit ctr, 2-bit useful,
    weak-provider alternate selector, deterministic one-bank allocation,
    pressure aging. No speculative history yet. Full history folding here is
    a reference equation, NOT a claim of constant-delay folded-history RTL.
    """
    def __init__(self, base=32, entries=16, lengths=(3, 7, 16), tag_bits=8,
                 sc=False, loop=False):
        assert all(x >= 2 and not x & (x-1) for x in (base, entries))
        self.base = [1] * base
        self.entries, self.lengths, self.tag_bits = entries, tuple(lengths), tag_bits
        self.tables = [[None] * entries for _ in lengths]
        self.history = 0
        self.epoch = 0
        self.alt_select = 0
        self.sc_enabled, self.loop_enabled = sc, loop
        self.weights = [[0]*entries for _ in range(3)]
        self.threshold = 8
        self.loops = [None]*4

    @property
    def bits(self):
        return (2*len(self.base) + len(self.lengths)*self.entries*(1+self.tag_bits+3+2)
                + max(self.lengths)+4+16+sum((self.entries.bit_length()-1)+2*self.tag_bits-1 for _ in self.lengths) + (self.entries*3*5+5 if self.sc_enabled else 0)
                + (4*(1+32+8+8+2+1) if self.loop_enabled else 0))

    def lookup(self, pc, **ignored):
        width = self.entries.bit_length()-1
        indices = [((pc >> 2) ^ fold(self.history, n, width)) & (self.entries-1) for n in self.lengths]
        tags = [((pc >> 2) ^ fold(self.history, n, self.tag_bits) ^
                 (fold(self.history, n, self.tag_bits-1)<<1)) & ((1<<self.tag_bits)-1) for n in self.lengths]
        hits = [i for i,(ix,t) in enumerate(zip(indices,tags)) if self.tables[i][ix] is not None and self.tables[i][ix]['tag']==t]
        provider = hits[-1] if hits else -1
        alternate = hits[-2] if len(hits)>1 else -1
        bi = (pc >> 2) & (len(self.base)-1)
        alt = self.tables[alternate][indices[alternate]]['ctr'] >= 0 if alternate>=0 else self.base[bi]>=2
        ctr = self.tables[provider][indices[provider]]['ctr'] if provider>=0 else (1 if alt else -2)
        raw = ctr>=0 if provider>=0 else alt
        tage = alt if provider>=0 and ctr in (-1,0) and self.alt_select>=0 else raw
        si = [(pc>>2)&(self.entries-1), ((pc>>2)^self.history)&(self.entries-1),
              ((pc>>2)^fold(self.history,max(self.lengths),width)^int(tage))&(self.entries-1)]
        total = (4 if tage else -4) + sum(2*self.weights[b][i]+1 for b,i in enumerate(si))
        pred = total>=0 if self.sc_enabled and abs(total)>=self.threshold else tage
        li=(pc>>2)&3;entry=self.loops[li];lp=None
        if self.loop_enabled and entry and entry['pc']==pc and entry['confidence']==3 and entry['trip']>0:
            lp = (not entry['direction']) if entry['current']+1 == entry['trip'] else entry['direction']
            pred = lp
        return {'layout':(len(self.base),self.entries,self.lengths,self.tag_bits),'pc':pc,'epoch':self.epoch,'indices':indices,'tags':tags,'base':bi,'provider':provider,
                'alternate':alternate,'alt':alt,'raw':raw,'weak':ctr in (-1,0),'tage':tage,
                'sc_indices':si,'sum':total,'loop':li,'prediction':bool(pred),'loop_prediction':lp}

    def train(self,q,taken):
        if q['epoch']!=self.epoch:return
        self.base[q['base']]=sat(self.base[q['base']],taken)
        p=q['provider']; ix=q['indices']
        # A delayed provider may have been replaced. Do not update another identity.
        entry=self.tables[p][ix[p]] if p>=0 else None
        present=entry is not None and entry['tag']==q['tags'][p]
        if present:
            entry['ctr']=sat(entry['ctr'],taken,-4,3)
            if q['raw'] != q['alt']:entry['u']=sat(entry['u'],q['raw']==taken)
            if q['weak'] and q['raw']!=q['alt']:self.alt_select=sat(self.alt_select,q['alt']==taken,-8,7)
        if q['tage']!=taken:
            free=[b for b in range(p+1,len(self.tables)) if self.tables[b][ix[b]] is None or self.tables[b][ix[b]]['u']==0]
            if free:
                b=free[0];self.tables[b][ix[b]]={'tag':q['tags'][b],'ctr':0 if taken else -1,'u':0}
            else:
                for b in range(p+1,len(self.tables)):self.tables[b][ix[b]]['u']=max(0,self.tables[b][ix[b]]['u']-1)
        if self.sc_enabled:
            sc=q['sum']>=0
            if sc != taken or abs(q['sum']) < self.threshold:
                for b,i in enumerate(q['sc_indices']):self.weights[b][i]=sat(self.weights[b][i],taken,-16,15)
            if sc != q['tage']:self.threshold=sat(self.threshold,sc!=taken,1,31)
        if self.loop_enabled:
            li=q['loop'];e=self.loops[li]
            if e is None or e['pc']!=q['pc']:
                self.loops[li]={'pc':q['pc'],'current':1,'trip':0,'direction':taken,'confidence':0,'age':0}
            elif taken == e['direction']:
                if e['current']==255:e['current']=0;e['trip']=0;e['confidence']=0
                else:e['current']+=1
            else:
                trip=e['current']+1
                e['confidence']=min(3,e['confidence']+1) if trip==e['trip'] else 0
                e['trip']=trip if trip<256 else 0;e['current']=0
        self.history=((self.history<<1)|int(taken))&((1<<max(self.lengths))-1)

    def invalidate(self):
        self.epoch+=1;self.history=0
        self.tables=[[None]*self.entries for _ in self.lengths];self.loops=[None]*4


class SpeculativeTage(ScaledTage):
    """Checkpoint recovery with explicit missing-history redirects at EX.

    Tables keep resolved training. Speculative GHR is advanced by accepted,
    identified conditional queries; flush repairs before any younger query.
    CPU integration must squash younger contexts when missing/different history
    is resolved, even when next_pc happened to match.
    """
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.resolved_history = 0

    def lookup(self, pc, **kwargs):
        result = super().lookup(pc, **kwargs)
        result['history_before'] = self.history
        return result

    def advance(self, query_accepted, conditional, prediction, training, taken,
                flush, invalidate):
        mask = (1 << max(self.lengths)) - 1
        before = self.history
        if invalidate:
            super().invalidate()
            self.resolved_history = 0
            return
        train = training is not None and training['epoch'] == self.epoch
        if train:
            super().train(training, taken)
            self.resolved_history = ((self.resolved_history << 1) | int(taken)) & mask
        if flush:
            self.history = (((training['history_before'] << 1) | int(taken)) & mask
                            if train else self.resolved_history)
        elif query_accepted and conditional:
            self.history = ((before << 1) | int(prediction)) & mask
        else:
            self.history = before


class LocalHistory:
    """Private local-history/PHT rows; a finite PC index aliases complete rows.

    Inspired by the two-level organization described by CVA6S+ (2025), not
    a reproduction of its RTL or published performance. PHT trains the saved
    query history; resolved local history advances using the current row.
    """
    def __init__(self, entries=128, history_bits=3):
        assert entries >= 2 and entries & (entries-1) == 0
        self.entries, self.history_bits = entries, history_bits
        self.histories = [0]*entries
        self.counters = [[1]*(1<<history_bits) for _ in range(entries)]
        self.epoch = 0

    @property
    def bits(self):
        return self.entries*(self.history_bits + 2*(1<<self.history_bits)) + 16

    def lookup(self, pc, **unused):
        row = (pc >> 2) & (self.entries-1)
        history = self.histories[row]
        return {'pc':pc, 'row':row, 'history':history, 'epoch':self.epoch,
                'prediction':self.counters[row][history]>=2}

    def train(self, query, taken):
        if query['epoch'] != self.epoch:
            return
        row, history = query['row'], query['history']
        self.counters[row][history] = sat(self.counters[row][history], taken)
        self.histories[row] = ((self.histories[row] << 1) | int(taken)) & ((1<<self.history_bits)-1)

    def invalidate(self):
        self.epoch += 1
        self.histories = [0]*self.entries
