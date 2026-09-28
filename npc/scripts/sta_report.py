"""Read whole-core mapped area and all four iEDA timing groups."""
import math
import re


def qualify_grid(measure, results, initial_estimate=None):
    """Find a measured pass point on 200..800 MHz; estimates only choose probes.

    `measure` runs all four timing groups and adds its record to `results`.
    Cached hold failures or non-monotone results require an exhaustive scan.
    """
    grid = list(range(200, 801, 20))
    if initial_estimate is not None and math.isfinite(initial_estimate) and initial_estimate > 0:
        first = max(200, min(800, int(initial_estimate // 20) * 20))
        if measure(first):
            if first == 800:
                return 800
            measure(first + 20)
        if not any(not value['passed'] for value in results.values()):
            if measure(800):
                return 800
    elif measure(800):
        return 800

    # A report's data-path estimate is not a qualification. It usually puts the
    # next real STA run near the boundary, avoiding several very low trial clocks.
    probe_source = min(int(f) for f, value in results.items() if not value['passed'])
    for _ in range(3):
        estimate = results[str(probe_source)]['groups']['data_max'].get('fmax_mhz')
        if estimate is None or not math.isfinite(estimate) or estimate <= 0:
            break
        probe = max(200, min(780, int(estimate // 20) * 20))
        if str(probe) in results:
            break
        if measure(probe):
            if probe < 780:
                measure(probe + 20)
            break
        # Input delays scale with the period in this SDC. A failed probe can
        # therefore provide a different estimate. Refine only the next probe;
        # no estimate ever counts as a pass or substitutes for the upper check.
        probe_source = probe

    passing = [grid.index(int(f)) for f, value in results.items() if value['passed']]
    failing = [grid.index(int(f)) for f, value in results.items() if not value['passed']]
    hold_failure = any(value['groups'][group]['slack_ns'] < 0 for value in results.values()
                       for group in ['data_min', 'gating_min'])
    if hold_failure or (passing and min(failing) < max(passing)):
        mhz = next((f for f in reversed(grid) if measure(f)), None)
    else:
        low, high = max(passing, default=-1), min(failing)
        while high - low > 1:
            middle = (low + high) // 2
            if measure(grid[middle]):
                low = middle
            else:
                high = middle
        mhz = grid[low] if low >= 0 else None
    if mhz is not None:
        assert measure(mhz)
        assert not measure(mhz + 20)
    return mhz


def mapped_cells(directory):
    stat = (directory / 'synth_stat.txt').read_text()
    cells = {name: int(count) for count, name in
             re.findall(r'^\s+(\d+)\s+[\d.eE+]+\s+(\w+_X\d+)\s*$', stat, re.M)}
    return {
        'area_um2': float(re.search(r"Chip area for module .*: ([\d.]+)", stat)[1]),
        'dff': sum(count for name, count in cells.items() if name.startswith('DFF')),
        'data_latches': sum(count for name, count in cells.items() if name.startswith('DL')),
        'clock_gates': sum(count for name, count in cells.items() if name.startswith('CLKGATE')),
        'cells': cells,
    }


def timing(directory):
    report = (directory / 'riscv32_core_reset_boundary.rpt').read_text()
    groups = {}
    for line in report.splitlines():
        row = [field.strip() for field in line.split('|')[1:-1]]
        if len(row) != 8 or row[2] not in ('max', 'min'):
            continue
        key = ('gating_' if 'gating' in row[1] else 'data_') + row[2]
        groups.setdefault(key, []).append({'endpoint': row[0], 'slack_ns': float(row[6]),
                                          'fmax_mhz': None if row[7] == 'NA' else float(row[7])})
    assert len(groups) == 4, groups
    return {key: min(rows, key=lambda row: row['slack_ns']) for key, rows in groups.items()}
