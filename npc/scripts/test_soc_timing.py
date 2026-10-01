#!/usr/bin/env python3
"""Check calibrated burst-write timing at integer and fractional CPU/device ratios."""
import subprocess
from pathlib import Path

NPC = Path(__file__).resolve().parents[1]


def main():
    for ratio in (1024, 2048, 2560, 7168):
        output = NPC / 'build/tests/soc-timing' / str(ratio)
        output.mkdir(parents=True, exist_ok=True)
        command = [
            'verilator', '--binary', '--timing', '--assert', '-Wno-fatal',
            '--top-module', 'axi4_write_calibration_tb', f'-GRATIO_SCALED={ratio}',
            '--Mdir', str(output / 'obj'),
            str(NPC.parent / 'ysyxSoC/perip/amba/device_clock.v'),
            str(NPC.parent / 'ysyxSoC/perip/amba/axi4_delayer.v'),
            str(NPC / 'tests/rtl/axi4_write_calibration_tb.sv'),
        ]
        with (output / 'test.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            cases = [(0, 0, 0, 0), (1, 0, 0, 0), (1, 2, 0, 0),
                     (8, 9, 0, 0), (1, 0, 2, 0), (3, 2, 2, 0),
                     (1, 2, 0, 13), (1, 2, 2, 17)]
            for initial, gap, device, response in cases:
                subprocess.run([str(output / 'obj/Vaxi4_write_calibration_tb'),
                                f'+INITIAL_GAP={initial}', f'+CPU_GAP={gap}',
                                f'+DEVICE_STALL={device}', f'+B_STALL={response}'],
                               stdout=log, stderr=subprocess.STDOUT, check=True)
        print(f'PASS: write burst calibration, ratio={ratio}/1024')


if __name__ == '__main__':
    main()
