#!/usr/bin/env python3
"""Passive observers must not change architectural work, cycles or result digest."""
import hashlib
import json
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
ROOT = NPC/'result/branch-v3'


def main():
    out = ROOT/'observer-neutrality'
    out.mkdir(exist_ok=False)
    results = []
    for name in ['B0-opportunity', 'H2E-narrow', 'R0-held', 'NSmallER-held']:
        index = ROOT/'rtl'/name/'index.json'
        for item in json.loads(index.read_text()):
            if item['name'] not in ['json_bpe-dev-2411', 'quant_loader-dev-2418']:
                continue
            command = [word for word in item['command']
                       if not word.startswith(('+events=', '+trace=', '+model_events='))]
            command.append('+observer=0')
            reference = next(line for line in (index.parent/(item['name']+'.log')).read_text().splitlines()
                             if line.startswith('RESULT '))
            result = subprocess.run(command, text=True, capture_output=True, check=True)
            log = out/(name+'-'+item['name']+'.log')
            log.write_text(result.stdout+result.stderr)
            assert 'PASS proxy' in result.stdout and reference in result.stdout
            results.append({'candidate': name, 'case': item['name'], 'command': command,
                            'matched': reference, 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
    (out/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print('PASS observer-neutrality', len(results))


if __name__ == '__main__':
    main()
