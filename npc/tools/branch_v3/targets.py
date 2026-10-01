"""Finite target components for M0/M1 diagnostics; lookup has no actual target."""
class TargetTable:
    def __init__(self, entries=16, ways=2):
        assert entries>=ways and entries%ways==0
        self.sets=[[] for _ in range(entries//ways)];self.ways=ways
        self.next=[0]*len(self.sets)
    def lookup(self,pc):
        row=self.sets[(pc>>2)%len(self.sets)]
        return next((t for p,t in row if p==pc),None)
    def train(self,pc,target):
        idx=(pc>>2)%len(self.sets);row=self.sets[idx]
        hit=next((i for i,(p,t) in enumerate(row) if p==pc),None)
        if hit is not None:row[hit]=(pc,target)
        elif len(row)<self.ways:row.append((pc,target))
        else:
            row[self.next[idx]]=(pc,target)
            self.next[idx]=(self.next[idx]+1)%self.ways

class IndirectHistory:
    """Last target base + finite tagged path contexts. Not full ITTAGE."""
    def __init__(self,entries=16):
        self.base=TargetTable(entries,2);self.history=0
        self.tables=[[None]*entries for _ in (4,12)]
        self.entries=entries
    def lookup(self,pc):
        indices=[((pc>>2)^(self.history&((1<<n)-1)))&(self.entries-1) for n in (4,12)]
        tags=[((pc>>2)^(self.history>>(n//2)))&255 for n in (4,12)]
        value=self.base.lookup(pc)
        for b,i in enumerate(indices):
            e=self.tables[b][i]
            if e is not None and e[0]==tags[b] and e[2]>0:value=e[1]
        return value,(pc,indices,tags)
    def train(self,context,target):
        pc,indices,tags=context;self.base.train(pc,target)
        for b,i in enumerate(indices):
            e=self.tables[b][i]
            if e is not None and e[0]==tags[b] and e[1]==target:self.tables[b][i]=(tags[b],target,min(3,e[2]+1))
            else:self.tables[b][i]=(tags[b],target,0)
    def advance_path(self,pc,target,taken):
        self.history=((self.history<<1)^(pc>>2)^(target>>2)^int(taken))&4095
