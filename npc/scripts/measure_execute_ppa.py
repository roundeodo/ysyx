#!/usr/bin/env python3
"""Freeze RV32 balanced RTL and measure area plus all-group STA on a 20 MHz grid."""
import argparse
from pathlib import Path
from select_icache_ppa import qualify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--name', default='current')
    parser.add_argument('--mul-pipeline', choices=[0, 1], type=int, default=0)
    parser.add_argument('--m-enable', choices=[0, 1], type=int, default=1)
    parser.add_argument('--source-root', type=Path, help='frozen tree containing npc/vsrc')
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    if Path(args.name).name != args.name or args.name in ['.', '..']:
        parser.error('--name must be a single directory name')
    qualify(args.name, args.output.resolve(), args.resume,
            cache_config=(1024, 4, 13, 32),
            source_root=args.source_root.resolve() if args.source_root else None,
            extra_make=[f'NPC_MULDIV_ENABLE={args.m_enable}',
                        f'NPC_MUL_PIPELINE_ENABLE={args.mul_pipeline}',
                        'NPC_BRANCH_HISTORY_ENTRY_COUNT=16',
                        'NPC_BRANCH_TARGET_ENTRY_COUNT=16',
                        'NPC_BRANCH_TARGET_WAY_COUNT=2',
                        'NPC_BRANCH_TARGET_WAY_BITS=0', 'NPC_BRANCH_TARGET_POLICY=0',
                        'NPC_BRANCH_DIRECTION_POLICY=0', 'NPC_BRANCH_GLOBAL_HISTORY_BITS=4',
                        'NPC_RETURN_STACK_ENTRY_COUNT=4'])


if __name__ == '__main__':
    main()
