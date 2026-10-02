#!/usr/bin/env python3
"""Freeze and qualify explicitly named predictor configurations with one flow."""
import argparse
import sys
from pathlib import Path

NPC = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NPC/'scripts'))
from select_icache_ppa import qualify
from followup_branch import defines

# Tuple columns: direction, SC, loop, early direct target, static choice.
CONFIGS = {
    'NSLER': (5, 1, 1, 1, 0),
    'NSL-victim': (5, 1, 1, 0, 0),
    'B0-victim': (0, 0, 0, 0, 0),
    'NSL-provider': (5, 1, 1, 0, 0),
    'NSL-parallel': (5, 1, 1, 0, 0),
    'SE0': (0, 0, 0, 1, 1),
    'R0-held': (0, 0, 0, 0, 0),
    'G256': (1, 0, 0, 0, 0),
    'NBase128': (5, 0, 0, 0, 0),
    'S': (0, 0, 0, 0, 1),
    'B64': (0, 0, 0, 0, 0),
    'G64': (1, 0, 0, 0, 0),
    'NSmall': (5, 0, 0, 0, 0),
    'NSmallER': (5, 0, 0, 1, 0),
    'R0': (0, 0, 0, 0, 0),
    'ER0': (0, 0, 0, 1, 0),
    'NER0': (5, 0, 0, 1, 0),
    'B0-current': (0, 0, 0, 0, 0),
    'H2-narrow': (0, 0, 0, 0, 2),
    'H2E-narrow': (0, 0, 0, 1, 2),
    'E0': (0, 0, 0, 1, 0),
    'N0': (5, 0, 0, 0, 0),
    'N0-widthfix': (5, 0, 0, 0, 0),
    'NL': (5, 0, 1, 0, 0),
    'NS': (5, 1, 0, 0, 0),
    'NSL': (5, 1, 1, 0, 0),
    'N0E': (5, 0, 0, 1, 0),
    'B32': (0, 0, 0, 0, 0),
}

ALIASES = {
    'H2E-delivery': 'H2E-narrow',
    'S-victim': 'S',
    'SE0-victim': 'SE0',
    'E0-victim': 'E0',
    'NER0-victim': 'NER0',
    'NSLER-victim': 'NSLER',
    'H2E-victim': 'H2E-narrow',
    'R0-victim': 'R0-held',
    'NSmallER-victim': 'NSmallER',
    'N0-victim': 'N0-widthfix',
    'NL-victim': 'NL',
    'NS-victim': 'NS',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='+', choices=[*CONFIGS, *ALIASES])
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    for name in args.names:
        config = ALIASES.get(name, name)
        direction, sc, loop, early, choice = CONFIGS[config]
        settings = defines({'direction_policy': direction,
                            'btb': 32 if config == 'B32' else 16,
                            'bht': 256 if config == 'G256' else
                                   64 if config in ('B64', 'G64') else 16})
        ras = config in ('R0', 'R0-held', 'ER0', 'NER0', 'NSmallER', 'NSLER')
        settings += [f'YSYX_BRANCH_EARLY_RAS={int(ras)}',
                     f'YSYX_BRANCH_SC_ENABLE={sc}', f'YSYX_BRANCH_LOOP_ENABLE={loop}',
                     f'YSYX_BRANCH_EARLY_TARGET={early}', f'YSYX_BRANCH_STATIC_POLICY={choice}']
        if config == 'NBase128':
            settings += ['YSYX_BRANCH_TAGE_BASE_ENTRIES=128']
        if config.startswith('NSmall'):
            settings += ['YSYX_BRANCH_TAGE_BASE_ENTRIES=16',
                         'YSYX_BRANCH_TAGE_TAGGED_ENTRIES=8', 'YSYX_BRANCH_TAGE_TAG_BITS=6',
                         'YSYX_BRANCH_TAGE_TABLE_COUNT=2',
                         'YSYX_BRANCH_TAGE_HISTORY_BITS_0=3', 'YSYX_BRANCH_TAGE_HISTORY_BITS_1=7']
        qualify(name, NPC/'result/branch-v3/ppa', args.resume,
                cache_config=(1024, 4, 13, 32),
                extra_make=[setting.replace('YSYX_', 'NPC_', 1) for setting in settings])


if __name__ == '__main__':
    main()
