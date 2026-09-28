#!/usr/bin/env python3
"""Qualify RV32I/IM with identical balanced resources, mapping and STA rules."""
import argparse
from pathlib import Path
from select_icache_ppa import qualify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--baseline', required=True, type=Path,
                        help='Frozen pre-M repository tree containing npc/vsrc')
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    for name, enabled in [('rv32i', 0), ('rv32im', 1), ('rv32i-current', 0)]:
        qualify(name, args.output.resolve(), args.resume, cache_config=(1024, 4, 13, 32),
                extra_make=[f'NPC_MULDIV_ENABLE={enabled}', 'NPC_BRANCH_HISTORY_ENTRY_COUNT=16',
                            'NPC_BRANCH_TARGET_ENTRY_COUNT=16', 'NPC_BRANCH_TARGET_WAY_COUNT=2',
                            'NPC_BRANCH_TARGET_WAY_BITS=0', 'NPC_BRANCH_TARGET_POLICY=0',
                            'NPC_BRANCH_DIRECTION_POLICY=0', 'NPC_BRANCH_GLOBAL_HISTORY_BITS=4',
                            'NPC_RETURN_STACK_ENTRY_COUNT=4'],
                source_root=args.baseline.resolve() if name == 'rv32i' else None)


if __name__ == '__main__':
    main()
