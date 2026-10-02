"""Finite target prototypes. Lookup never accepts branch outcomes.

Region replacement invalidates all referencing entries. Compact entries retain
full PC identity, check representability and migrate to fitting ways.
"""
from collections import deque


def decode(pc, word):
    opcode, rd, rs1 = word & 127, (word >> 7) & 31, (word >> 15) & 31
    if opcode == 0x63 and ((word >> 12) & 7) in (0, 1, 4, 5, 6, 7):
        immediate = ((word >> 31) << 12) | (((word >> 7) & 1) << 11)
        immediate |= ((word >> 25) & 63) << 5 | ((word >> 8) & 15) << 1
        immediate -= (1 << 13) if immediate & (1 << 12) else 0
        return 0, (pc + immediate) & 0xffffffff, immediate
    if opcode == 0x6f:
        immediate = ((word >> 31) << 20) | (((word >> 12) & 255) << 12)
        immediate |= ((word >> 20) & 1) << 11 | ((word >> 21) & 1023) << 1
        immediate -= (1 << 21) if immediate & (1 << 20) else 0
        return 1, (pc + immediate) & 0xffffffff, immediate
    if opcode == 0x67 and ((word >> 12) & 7) == 0:
        immediate = word >> 20
        immediate -= (1 << 12) if immediate & 2048 else 0
        is_return = rs1 in (1, 5) and (rd not in (1, 5) or rd != rs1) and immediate == 0
        return (3 if is_return else 2), None, immediate
    return None, None, 0


class Btb:
    def __init__(self, entries=32, ways=4, index=2, policy=2, admission=2,
                 widths=None, regions=0):
        self.entries, self.ways = entries, ways
        self.index_policy, self.policy, self.admission = index, policy, admission
        self.widths, self.region_count = widths, regions
        self.rows = [[None] * ways for _ in range(entries // ways)]
        self.reuse = [[3] * ways for _ in self.rows]
        self.next = [0] * len(self.rows)
        self.regions = [None] * regions
        self.region_next = 0
        self.rejected = self.region_evictions = self.migrations = 0

    def index(self, pc):
        bits = (len(self.rows) - 1).bit_length()
        word, value = pc >> 2, pc >> 2
        if self.index_policy == 1:
            value ^= word >> bits
        elif self.index_policy == 2:
            for shift in range(bits, 30, bits):
                value ^= word >> shift
        return value & (len(self.rows) - 1)

    def lookup(self, pc):
        for way, entry in enumerate(self.rows[self.index(pc)]):
            if entry is not None and entry[0] == pc:
                _, payload, kind, region = entry
                if self.region_count:
                    assert self.regions[region] is not None
                    target = (self.regions[region] << 16) | payload
                elif self.widths and self.widths[way] < 32:
                    width = self.widths[way]
                    target = (pc & ~((1 << width) - 1)) | payload
                else:
                    target = payload
                return target, kind
        return None

    def train(self, pc, target, kind, taken, prefill=False):
        set_index = self.index(pc)
        row, ages = self.rows[set_index], self.reuse[set_index]
        hit = next((w for w, e in enumerate(row) if e is not None and e[0] == pc), None)
        if prefill and hit is not None:
            return  # Hints cannot overwrite an execution-trained resident.
        if hit is None and self.admission == 2 and kind == 0 and not taken:
            return
        fitting = list(range(self.ways))
        if self.widths:
            fitting = [w for w, width in enumerate(self.widths)
                       if width == 32 or pc >> width == target >> width]
            if hit is not None and hit not in fitting:
                row[hit] = None
                ages[hit] = 3
                self.migrations += 1
                hit = None
            if not fitting:
                self.rejected += 1
                return
        region = None
        if self.region_count:
            prefix = target >> 16
            region = next((i for i, v in enumerate(self.regions) if v == prefix), None)
            if region is None:
                region = next((i for i, v in enumerate(self.regions) if v is None), None)
                if region is None:
                    region = self.region_next
                    self.region_next = (region + 1) % self.region_count
                    self.region_evictions += 1
                    for s, entries in enumerate(self.rows):
                        for w, entry in enumerate(entries):
                            if entry is not None and entry[3] == region:
                                entries[w] = None
                                self.reuse[s][w] = 3
                self.regions[region] = prefix
            hit = next((w for w, e in enumerate(row) if e is not None and e[0] == pc), None)
        empty = next((w for w in fitting if row[w] is None), None)
        if hit is not None:
            selected = hit
        elif empty is not None:
            selected = empty
        elif self.policy == 2:
            maximum = max(ages[w] for w in fitting)
            selected = next(w for w in fitting if ages[w] == maximum)
            for w in fitting:
                ages[w] += 3 - maximum
        else:
            selected = next(w for offset in range(self.ways)
                            if (w := (self.next[set_index] + offset) % self.ways) in fitting)
        replacing = row[selected] is not None and hit is None
        if self.policy == 2:
            if hit is None:
                ages[selected] = 2
            elif taken:
                ages[selected] = 0
        elif replacing:
            self.next[set_index] = (selected + 1) % self.ways
        payload = target
        if self.region_count:
            payload &= 65535
        elif self.widths:
            payload &= (1 << self.widths[selected]) - 1
        row[selected] = (pc, payload, kind, region)

    def clear(self):
        for s in range(len(self.rows)):
            self.rows[s] = [None] * self.ways
            self.reuse[s] = [3] * self.ways
            self.next[s] = 0
        self.regions = [None] * self.region_count
        self.region_next = 0

    @property
    def bits(self):
        tag = 30 - (len(self.rows) - 1).bit_length()
        targets = (sum(self.widths) * len(self.rows) if self.widths else
                   self.entries * (16 + (self.region_count - 1).bit_length())
                   if self.region_count else self.entries * 32)
        extra = self.region_count * 17 + (self.region_count - 1).bit_length() if self.region_count else 0
        replacement = self.entries * 2 if self.policy == 2 else len(self.rows) * (self.ways - 1).bit_length()
        return self.entries * (tag + 1 + 2) + targets + extra + replacement


class Metadata:
    """Exact 1KiB/4-way cache residence from observed tag/word writes."""
    def __init__(self):
        self.rows = [[{'base': None, 'valid': False, 'words': {}} for _ in range(4)] for _ in range(8)]

    def apply(self, events):
        installs = []
        for fields in events:
            if fields[0] == 'V':
                self.__init__()
                installs = []
                continue
            _, _, s, w, number, value = fields
            row = self.rows[int(s)][int(w)]
            if fields[0] == 'L':
                base = int(value, 16)
                if number == '0':
                    row.update(base=base, valid=False, words={})
                else:
                    assert row['base'] == base
                    row['valid'] = True
                    installs.append(row)
            else:
                row['words'][int(number)] = int(value, 16)
        # The last D and install L share an edge; decode after both have applied.
        for row in installs:
            assert len(row['words']) == 8
        return [(row['base'], dict(row['words'])) for row in installs]

    def lookup(self, pc):
        for row in self.rows[(pc >> 5) & 7]:
            if row['valid'] and row['base'] == pc & ~31:
                return decode(pc, row['words'][(pc >> 2) & 7])
        return None


class Prefill:
    """Four hints maximum; one idle write/clock; resolution owns the write port."""
    def __init__(self, backward_only=False):
        self.table = Btb()
        self.queue = deque()
        self.backward_only = backward_only
        self.dropped = self.writes = 0

    def enqueue(self, installs):
        for base, words in installs:
            for index in range(8):
                pc = base + 4 * index
                kind, target, immediate = decode(pc, words[index])
                if kind not in (0, 1) or (self.backward_only and kind == 0 and immediate >= 0):
                    continue
                if len(self.queue) == 4:
                    self.dropped += 1
                else:
                    self.queue.append((pc, target, kind))

    def tick(self, count=1):
        for _ in range(min(count, len(self.queue))):
            pc, target, kind = self.queue.popleft()
            self.table.train(pc, target, kind, True, prefill=True)
            self.writes += 1

    def clear(self):
        self.queue.clear()
        self.table.clear()
