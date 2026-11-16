#!/usr/bin/env python3
"""Attribute mapped cell area by retained instance names, not RTL bit counts."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('netlist_json', type=Path)
    parser.add_argument('--liberty', type=Path, required=True)
    parser.add_argument('--top', default='riscv32_core_reset_boundary')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--grouping', type=Path,
                        help='Reviewed instance and top output-signal prefix groups')
    args = parser.parse_args()
    design = json.loads(args.netlist_json.read_text())
    areas = {name: float(area) for name, area in re.findall(
        r'cell\s*\(\s*(\w+)\s*\).*?\barea\s*:\s*([\d.]+)',
        args.liberty.read_text(), re.S)}
    by_instance = defaultdict(float)
    by_subinstance = defaultdict(float)
    by_type = defaultdict(float)
    by_section = defaultdict(float)
    grouping = json.loads(args.grouping.read_text()) if args.grouping else {}
    assignments = []
    for name, cell in design['modules'][args.top]['cells'].items():
        cell_type = cell['type']
        if cell_type not in areas:
            raise SystemExit(f'Cell has no Liberty area: {name}: {cell_type}')
        match = re.search(r'u_core\.(u_\w+)(?:\.|$)', name)
        owner = match[1] if match else 'shared_or_reset_or_unattributed'
        child = re.search(r'u_core\.(u_\w+)\.(u_\w+)(?:\.|$)', name)
        subowner = '.'.join(child.groups()) if child else owner
        area = areas[cell_type]
        section = grouping.get('instances', {}).get(owner)
        if section is None:
            for prefix, group in sorted(grouping.get('signal_prefixes', {}).items(),
                                        key=lambda pair: -len(pair[0])):
                if name.startswith(prefix):
                    section = group
                    break
        if section is None:
            section = 'shared_reset_unattributed'
        by_section[section] += area
        by_instance[owner] += area
        by_subinstance[subowner] += area
        by_type[cell_type] += area
        assignments.append({'cell': name, 'type': cell_type, 'owner': owner,
                            'section': section, 'area_um2': area})
    total = sum(by_instance.values())
    rows = [{'instance': name, 'area_um2': round(area, 6),
             'percent': 100 * area / total}
            for name, area in sorted(by_instance.items(), key=lambda pair: -pair[1])]
    result = {'method': 'Mapped-cell instance-name attribution. Flattening and shared '
              'optimization limit attribution; removal deltas require a separate run.',
              'total_area_um2': round(total, 6), 'cell_count': len(assignments),
              'netlist_sha256': hashlib.sha256(args.netlist_json.read_bytes()).hexdigest(),
              'liberty_sha256': hashlib.sha256(args.liberty.read_bytes()).hexdigest(),
              'by_instance': rows, 'by_subinstance_um2': dict(by_subinstance),
              'by_section': [{'section': name, 'area_um2': round(area, 6),
                              'percent': 100 * area / total}
                             for name, area in sorted(by_section.items(), key=lambda p: -p[1])],
              'grouping': grouping,
              'by_cell_type_um2': dict(by_type), 'assignments': assignments}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'assignments'}, indent=2))


if __name__ == '__main__':
    main()
