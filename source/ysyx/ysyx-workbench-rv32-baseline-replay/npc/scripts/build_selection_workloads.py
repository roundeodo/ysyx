#!/usr/bin/env python3
"""Freeze independent references, native checks and RV32I images before tuning."""
import argparse
from collections import Counter
import ctypes
import hashlib
import json
from pathlib import Path
import random
import subprocess
import zlib

NPC = Path(__file__).resolve().parents[1]
TEST = NPC / "tests/frontend_selection"
MASK = 0xffffffff


def mix(h, value):
    return ((h * 33) ^ value) & MASK


def merge_vocabulary():
    # Fixed vocabulary corpus, independent of every development/held input.
    text = ("the model processes input tokens and output tensors with a runtime command queue. "
            "load quantized weights, decode text, schedule compute and return results. ") * 4
    tokens = list(text.encode())
    merges = []
    for rank in range(24):
        counts = Counter(zip(tokens, tokens[1:]))
        pair = min(counts, key=lambda p: (-counts[p], p))
        merges.append(pair)
        output = []
        i = 0
        while i < len(tokens):
            if i + 1 < len(tokens) and tuple(tokens[i:i+2]) == pair:
                output.append(256 + rank); i += 2
            else:
                output.append(tokens[i]); i += 1
        tokens = output
    return merges


def encode(h, text, merges):
    tokens = list(text.encode())
    ranks = {pair: rank for rank, pair in enumerate(merges)}
    while len(tokens) > 1:
        candidates = [(ranks[pair], i) for i, pair in enumerate(zip(tokens, tokens[1:])) if pair in ranks]
        if not candidates:
            break
        rank, i = min(candidates)
        tokens[i:i+2] = [256 + rank]
    h = mix(h, len(tokens))
    for token in tokens:
        h = mix(h, token)
    return h


def json_reference(h, node, merges):
    if isinstance(node, str):
        return encode(mix(h, 1), node, merges)
    if isinstance(node, bool):
        return mix(mix(h, 3), int(node))
    if isinstance(node, int):
        return mix(mix(h, 2), node & MASK)
    if node is None:
        return mix(h, 4)
    h = mix(h, 5 if isinstance(node, list) else 6)
    if isinstance(node, list):
        for value in node:
            h = json_reference(h, value, merges)
    else:
        for key, value in node.items():
            h = json_reference(encode(h, key, merges), value, merges)
    return h


def inputs(kind, seed, held):
    rng = random.Random(seed)
    if kind == 0:
        vocabulary = ["model", "tokens", "cache", "queue", "input", "output"]
        if held:
            vocabulary += ["工具", "audio", "image", "unknown", "result", "雪"]
        obj = {"messages": [{"role": rng.choice(["user", "tool"]),
                "text": " ".join(rng.choices(vocabulary, k=3 if held else 2))}
               for _ in range(3 if held else 2)],
               "limit": rng.randrange(1, 512), "stream": bool(seed & 1), "optional": None}
        return json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode(), obj
    if kind == 1:
        size = 2048 if held else 1024
        raw = bytes(rng.randrange(256) if i % 64 < (12 if held else 4)
                    else ((i >> 4) * 17 + (i & 3)) & 255 for i in range(size))
        return zlib.compress(raw, level=6), raw
    count = 18 if held else 10
    commands = [{"id": i, "left": rng.randrange(-1, i) if i else -1,
                 "right": rng.randrange(-1, i) if i else -1,
                 "op": rng.randrange(8), "value": rng.randrange(-2048, 2048)} for i in range(count)]
    if held:
        rng.shuffle(commands)
    return json.dumps({"commands": commands}, separators=(",", ":")).encode(), commands


def reference(kind, payload, repeats, merges):
    h = 5381
    for _ in range(repeats):
        if kind == 0:
            h = json_reference(h, payload, merges)
        elif kind == 1:
            values = []
            for i, byte in enumerate(payload):
                a, b = (byte & 15) - (16 if byte & 8 else 0), (byte >> 4) - (16 if byte & 128 else 0)
                bias = (i & 15) - 7
                values += [max(-48, min(47, a * 8 + bias)), max(-48, min(47, b * 8 - bias))]
            for block in range(0, len(values), 64):
                for lane in range(8):
                    for row in range(8):
                        h = mix(h, values[block + row * 8 + lane] & 255)
        else:
            values = {}
            while len(values) < len(payload):
                before = len(values)
                for node in payload:
                    i, left, right, op, immediate = (node[k] for k in ("id", "left", "right", "op", "value"))
                    if i in values or (left >= 0 and left not in values) or (right >= 0 and right not in values):
                        continue
                    a = values[left] if left >= 0 else immediate & MASK
                    b = values[right] if right >= 0 else (immediate ^ 0x31) & MASK
                    n = b & 31
                    v = (a & 65535) - 32768; bound = (b & 255) + 1
                    x = (a ^ (a << 13)) & MASK; x ^= x >> 17; x = (x ^ (x << 5)) & MASK
                    candidates = [a + b, (a << n) | (a >> ((32 - n) & 31)),
                                  max(-bound, min(bound, v)), ((a & 0x55555555) << 1) | ((b & 0xaaaaaaaa) >> 1),
                                  x ^ b, a.bit_count() + b, b if a & 0x80000000 else a + b, max(a, b)]
                    values[i] = candidates[op] & MASK
                    h = mix(mix(h, i), values[i])
                assert len(values) > before
    return h


def headers(directory):
    definitions = {
        "stdint.h": "typedef signed char int8_t; typedef unsigned char uint8_t; typedef short int16_t; typedef unsigned short uint16_t; typedef int int32_t; typedef unsigned int uint32_t; typedef long long int64_t; typedef unsigned long long uint64_t; typedef unsigned int uintptr_t;\n",
        "stdlib.h": "#include <stddef.h>\nvoid *malloc(size_t); void free(void *); void *realloc(void *,size_t); void abort(void) __attribute__((noreturn)); double strtod(const char *,char **);\n",
        "string.h": "#include <stddef.h>\nvoid *memcpy(void *,const void *,size_t); void *memmove(void *,const void *,size_t); void *memset(void *,int,size_t); int memcmp(const void *,const void *,size_t); size_t strlen(const char *); int strcmp(const char *,const char *); int strncmp(const char *,const char *,size_t);\n",
        "stdio.h": "#include <stddef.h>\ntypedef void FILE; int sprintf(char *,const char *,...); int snprintf(char *,size_t,const char *,...); int sscanf(const char *,const char *,...);\n",
        "math.h": "#define NAN (__builtin_nan(\"\"))\n#define INFINITY (__builtin_inf())\n#define isnan(x) __builtin_isnan(x)\n#define isinf(x) __builtin_isinf(x)\n#define fabs(x) __builtin_fabs(x)\n",
        "ctype.h": "int tolower(int);\n", "limits.h": "#define INT_MAX 2147483647\n#define INT_MIN (-INT_MAX-1)\n#define UINT_MAX 4294967295u\n",
        "float.h": "#define DBL_EPSILON __DBL_EPSILON__\n", "assert.h": "#include <stdlib.h>\n#define assert(x) ((x) ? (void)0 : abort())\n"}
    directory.mkdir()
    for name, body in definitions.items():
        (directory / name).write_text("#pragma once\n" + body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dev-seeds", type=int, nargs=2, default=[41, 73])
    parser.add_argument("--held-seeds", type=int, nargs=2, default=[809, 1543])
    args = parser.parse_args(); out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    if len(set(args.dev_seeds + args.held_seeds)) != 4:
        parser.error("development and held seeds must be distinct")
    headers(out / "include")
    merges = merge_vocabulary()
    sources = [TEST / "workload.c", TEST / "vendor/cJSON/cJSON.c", TEST / "vendor/miniz/miniz_tinfl.c"]
    common = ["-O2", "-fno-builtin", "-ffunction-sections", "-fdata-sections", "-I", str(TEST / "vendor/cJSON"), "-I", str(TEST / "vendor/miniz")]
    common += ["-D" + d for d in ("MINIZ_NO_STDIO", "MINIZ_NO_TIME", "MINIZ_NO_DEFLATE_APIS", "MINIZ_NO_ARCHIVE_APIS", "MINIZ_NO_ZLIB_APIS", "MINIZ_NO_MALLOC", "MINIZ_USE_UNALIGNED_LOADS_AND_STORES=0")]
    gcc_include = subprocess.check_output(["riscv64-linux-gnu-gcc", "-print-file-name=include"], text=True).strip()
    cases = []
    for held, seeds in ((False, args.dev_seeds), (True, args.held_seeds)):
        for kind, name in enumerate(("json_bpe", "quant_loader", "runtime_graph")):
            for seed in seeds:
                label = f'{name}-{"held" if held else "dev"}-{seed}'
                folder = out / label; folder.mkdir()
                data, payload = inputs(kind, seed, held); repeats = 2
                expected = reference(kind, payload, repeats, merges)
                raw_bytes = len(payload) if kind == 1 else 0
                stored = data if kind == 1 else data + b"\0"
                header = (f"#define WORKLOAD {kind}\n#define REPEATS {repeats}\n#define RAW_BYTES {raw_bytes}\n#define MERGE_COUNT {len(merges)}\n"
                          + "static const unsigned char input[] = {" + ",".join(map(str, stored)) + "};\n"
                          + "static const unsigned short merges[][2] = {" + ",".join("{%d,%d}" % pair for pair in merges) + "};\n")
                (folder / "input.h").write_text(header)
                (folder / "payload.bin").write_bytes(data)
                def run(command, log):
                    with (folder / log).open("x") as stream:
                        subprocess.run(list(map(str, command)), stdout=stream, stderr=subprocess.STDOUT, check=True)
                native = ["gcc", *common, "-DFRONTEND_HOST", "-shared", "-fPIC", "-I", folder, *sources, "-o", folder / "native.so"]
                run(native, "native.log")
                library = ctypes.CDLL(str(folder / "native.so")); library.run.restype = ctypes.c_uint32
                actual = library.run(); assert actual == expected, (label, hex(actual), hex(expected))
                elf, binary = folder / "image.elf", folder / "image.bin"
                helpers = NPC.parent / "abstract-machine/am/src/riscv/npc/libgcc"
                command = ["riscv64-linux-gnu-gcc", *common, "-march=rv32i_zicsr_zifencei", "-mabi=ilp32", "-mstrict-align", "-msmall-data-limit=0",
                           "-fno-pic", "-fno-stack-protector", "-nostdlib", "-nostdinc", "-isystem", gcc_include, "-I", out / "include", "-I", folder,
                           "-static", "-Wl,--gc-sections,--build-id=none", "-Wl,-Map=" + str(folder / "image.map"), "-T", NPC / "tests/frontend_exploration/link.ld",
                           NPC / "tests/frontend_exploration/start.S", *sources, TEST / "runtime.c", helpers / "div.S", helpers / "muldi3.S", "-o", elf]
                run(command, "build.log")
                run(["riscv64-linux-gnu-objcopy", "-O", "binary", elf, binary], "objcopy.log")
                image = binary.read_bytes(); image += b"\0" * (-len(image) % 4)
                (folder / "image.hex").write_text("".join(f'{int.from_bytes(image[i:i+4], "little"):08x}\n' for i in range(0, len(image), 4)))
                symbols = subprocess.check_output(["riscv64-linux-gnu-nm", str(elf)], text=True)
                addresses = {row.split()[2]: int(row.split()[0], 16) for row in symbols.splitlines() if len(row.split()) == 3}
                cases.append({"name": label, "kind": name, "seed": seed, "held": held, "expected": expected,
                              "begin_pc": addresses["workload_begin"], "end_pc": addresses["workload_end"],
                              "image_bytes": len(image), "command": list(map(str, command)), "native_command": list(map(str, native)),
                              "hashes": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (elf, binary, folder / "input.h")}})
                (out / "manifest.json").write_text(json.dumps({"cases": cases, "sources": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources, TEST / "runtime.c", Path(__file__)]}, "held_policy": "selection frozen before held performance execution"}, indent=2) + "\n")
                print("PASS native/reference and RV32 build", label, len(image), flush=True)


if __name__ == "__main__":
    main()
