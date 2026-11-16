#!/usr/bin/env python3
"""Build isolated RV32I NEMU/MicroBench sources and record a functional PC trace.

The isolated NEMU timer returns instruction ordinals for deterministic output.
Its printed seconds are NOT CPU performance. Use RTL for all timing claims.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scale", choices=("test", "train"), default="test")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    generator_source = Path(__file__).read_bytes()
    (output / "generator-source.py").write_bytes(generator_source)
    manifest = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "scale": args.scale, "isa": "rv32i_zicsr", "commands": [],
                "timer": "NEMU instruction ordinal, only for deterministic functional replay; no physical timing",
                "software_platform": "NEMU RAM at 0x80000000, differs from SoC-linked MicroBench",
                "source_hashes": {}, "copied_source_changes": [],
                "script_sha256": hashlib.sha256(generator_source).hexdigest()}
    (output / "workspace.diff").write_bytes(subprocess.check_output(["git", "diff", "--binary"], cwd=ROOT))
    (output / "submodules.txt").write_bytes(subprocess.check_output(["git", "submodule", "status"], cwd=ROOT))
    for original, target in (("nemu", "nemu"), ("abstract-machine", "abstract-machine"),
                             ("am-kernels/benchmarks/microbench", "microbench")):
        shutil.copytree(ROOT / original, output / target,
                        ignore=shutil.ignore_patterns("build", ".git", "__pycache__"))
        for path in sorted((output / target).rglob("*")):
            if path.is_file():
                manifest["source_hashes"][str(path.relative_to(output))] = sha(path)
    nemu, am, bench = output / "nemu", output / "abstract-machine", output / "microbench"
    architecture = am / "scripts/riscv32-nemu.mk"
    architecture.write_text(architecture.read_text().replace("-march=rv32im_zicsr", "-march=rv32i_zicsr")
                            + "\nAM_SRCS += riscv/npc/libgcc/div.S riscv/npc/libgcc/muldi3.S "
                            "riscv/npc/libgcc/multi3.c riscv/npc/libgcc/ashldi3.c riscv/npc/libgcc/unused.c\n")
    timer = nemu / "src/device/timer.c"
    original = timer.read_text()
    assert original.count("uint64_t us = get_time();") == 1
    timer.write_text(original.replace("uint64_t us = get_time();",
                                     "extern uint64_t g_nr_guest_inst;\n    uint64_t us = g_nr_guest_inst;"))
    config = nemu / "configs/riscv32-capacity_defconfig"
    config.write_text((nemu / "configs/riscv32-cachesim_defconfig").read_text()
                      + "\n# CONFIG_HAS_KEYBOARD is not set\nCONFIG_HAS_VGA=y\n"
                      "CONFIG_VGA_SHOW_SCREEN=y\n"
                      "# CONFIG_HAS_AUDIO is not set\n# CONFIG_HAS_DISK is not set\n"
                      "# CONFIG_HAS_SDCARD is not set\n")
    for path in (architecture, timer, config):
        manifest["copied_source_changes"].append({"path": str(path.relative_to(output)), "sha256": sha(path)})
    environment = dict(os.environ, NEMU_HOME=str(nemu), AM_HOME=str(am),
                       SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    def run(command, cwd, log):
        manifest["commands"].append({"argv": list(map(str, command)), "cwd": str(cwd), "log": log})
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(log, flush=True)
        with (output / log).open("x") as stream:
            subprocess.run(list(map(str, command)), cwd=cwd, env=environment,
                           stdout=stream, stderr=subprocess.STDOUT, check=True)
    run(["make", "git_commit=", "riscv32-capacity_defconfig"], nemu, "nemu-config.log")
    run(["make", "git_commit=", "-j2"], nemu, "nemu-build.log")
    run(["make", "git_commit=", "ARCH=riscv32-nemu", "mainargs=" + args.scale, "-j2", "insert-arg"],
        bench, "image-build.log")
    binary = bench / "build/microbench-riscv32-nemu.bin"
    elf = binary.with_suffix(".elf")
    run(["riscv64-linux-gnu-readelf", "-A", elf], output, "isa.log")
    attributes = (output / "isa.log").read_text()
    match = re.search(r'Tag_RISCV_arch:\s*"([^"]+)"', attributes)
    extensions = match[1].split("_") if match else []
    if (not extensions or not re.fullmatch(r"rv32i(?:\d+p\d+)?", extensions[0])
            or any(not re.fullmatch(r"(?:zicsr|zifencei)(?:\d+p\d+)?", name)
                   for name in extensions[1:])):
        raise RuntimeError("image ISA exceeds RV32I/Zicsr/Zifencei")
    interpreter = nemu / "build/riscv32-nemu-interpreter"
    trace = output / "microbench.trace.bin"
    run([interpreter, "-b", "--cachesim-trace=" + str(trace), binary], output, "trace.log")
    log = (output / "trace.log").read_text()
    if "HIT GOOD TRAP" not in log or "FAIL" in log or "Ignored" in log:
        raise RuntimeError("MicroBench did not complete all functional checks")
    manifest["artifacts"] = {str(path.relative_to(output)): sha(path)
                             for path in (binary, elf, interpreter, trace, nemu / ".config")}
    manifest["validation"] = "all benchmark checks and GOOD TRAP; not a timing measurement"
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
