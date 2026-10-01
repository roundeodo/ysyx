#!/usr/bin/env python3
"""Freeze RV32 balanced RTL and measure area plus all-group STA on a 20 MHz grid."""
import argparse
from pathlib import Path
from select_icache_ppa import qualify
from result_workspace import ResultWorkspace

NPC = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend-rob', choices=[0, 1], type=int, default=0)
    parser.add_argument('--backend-entries', choices=[2, 4, 8], type=int, default=4)
    parser.add_argument('--load-overlap', choices=[0, 1], type=int, default=0)
    parser.add_argument('--lsu-entries', choices=[1, 2], type=int, default=1)
    parser.add_argument('--dcache-hit-under-miss', choices=[0, 1], type=int, default=0)
    parser.add_argument('--output', type=Path, default=NPC / 'result/execute-ppa-current')
    parser.add_argument('--keep-artifacts', action='store_true')
    parser.add_argument('--name', default='current')
    parser.add_argument('--mul-pipeline', choices=[0, 1], type=int, default=0)
    parser.add_argument('--m-enable', choices=[0, 1], type=int, default=1)
    parser.add_argument('--source-root', type=Path, help='frozen tree containing npc/vsrc')
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    if Path(args.name).name != args.name or args.name in ['.', '..']:
        parser.error('--name must be a single directory name')
    with ResultWorkspace(NPC, args.output, 'ppa', resume=args.resume, keep=args.keep_artifacts):
        qualify(args.name, args.output.resolve(), args.resume,
                cache_config=(1024, 4, 13, 32),
                source_root=args.source_root.resolve() if args.source_root else None,
                extra_make=[f'NPC_BACKEND_ROB_ENABLE={args.backend_rob}',
                            f'NPC_BACKEND_ENTRIES={args.backend_entries}',
                            f'NPC_BACKEND_LOAD_OVERLAP={args.load_overlap}',
                       f'NPC_LSU_ENTRIES={args.lsu_entries}',
                       f'NPC_DCACHE_HIT_UNDER_MISS={args.dcache_hit_under_miss}',
                            f'NPC_MULDIV_ENABLE={args.m_enable}',
                            f'NPC_MUL_PIPELINE_ENABLE={args.mul_pipeline}',
                            'NPC_BRANCH_HISTORY_ENTRY_COUNT=16',
                            'NPC_BRANCH_TARGET_ENTRY_COUNT=16',
                            'NPC_BRANCH_TARGET_WAY_COUNT=2',
                            'NPC_BRANCH_TARGET_WAY_BITS=0', 'NPC_BRANCH_TARGET_POLICY=0',
                            'NPC_BRANCH_DIRECTION_POLICY=0', 'NPC_BRANCH_GLOBAL_HISTORY_BITS=4',
                            'NPC_RETURN_STACK_ENTRY_COUNT=4'])


if __name__ == '__main__':
    main()
