#!/usr/bin/env python3
"""Fetch the immutable author artifact; do not redistribute its source in Git."""
import hashlib,json,subprocess,tarfile
from pathlib import Path
NPC=Path(__file__).resolve().parents[2];r=NPC/'result/branch-v3/references';r.mkdir(parents=True,exist_ok=True)
record=json.loads((NPC/'docs/research/branch-v3/author-artifact.json').read_text())
archive=r/'AndreSeznecLimited.tar.gz'
if not archive.exists():subprocess.run(['curl','--fail','--location','--retry','3','--max-time','120',record['url'],'-o',str(archive)],check=True)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==record['sha256']
with tarfile.open(archive) as tar:
    for entry in tar.getmembers():
        assert not entry.issym() and not entry.islnk()
        assert (r/entry.name).resolve().is_relative_to(r.resolve())
    tar.extractall(r)
stubs=r/'adapter';stubs.mkdir(exist_ok=True)
(stubs/'utils.h').write_text('#pragma once\n#include <cstdint>\ntypedef uint64_t UINT64; typedef uint32_t UINT32;\nenum OpType {OPTYPE_RET_UNCOND,OPTYPE_JMP_INDIRECT_UNCOND,OPTYPE_JMP_INDIRECT_COND,OPTYPE_CALL_INDIRECT_UNCOND,OPTYPE_CALL_INDIRECT_COND,OPTYPE_RET_COND,OPTYPE_JMP_DIRECT_COND,OPTYPE_CALL_DIRECT_COND,OPTYPE_JMP_DIRECT_UNCOND,OPTYPE_CALL_DIRECT_UNCOND};\n')
for name in ['bt9.h','bt9_reader.h']:(stubs/name).write_text('')
subprocess.run(['g++','-O2','-fwrapv','-std=c++17','-I',str(stubs),'-I',str(r/'AndreSeznecLimited/cbp8KB'),str(NPC/'tools/branch_v3/author_reference.cpp'),'-o',str(r/'author8')],check=True)
print('PASS unmodified author predictor built')
