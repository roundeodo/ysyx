# NPC Microarchitecture Notes

This directory records the reasoning behind CPU and SoC module designs. It is a
long-lived engineering log, not a replacement for comments next to RTL.

## Document Roles

- `MODULE_DESIGN_RECORD_TEMPLATE.md`: template used before implementing a new
  architectural module or changing an existing module boundary.
- `<MODULE>_DESIGN_RECORD.md`: stable requirements, ownership, interface contracts,
  microarchitecture, invariants, and accepted decisions for one module.
- `EXPERIMENT_LOG.md`: append-only measurements tied to a configuration and Git commit.

The architecture authority remains
[`ARCHITECTURE_PLAN.md`](../../vsrc/riscv32/doc/ARCHITECTURE_PLAN.md). The naming and source
organization authority remains
[`NAMING_GUIDE.md`](../../vsrc/riscv32/doc/NAMING_GUIDE.md).

## Required Workflow

1. Before RTL, create or update the module design record. State the problem, measurable
   goals, ownership boundary, interface contract, state/data structures, correctness
   invariants, and verification plan.
2. Compare at least two relevant open-source designs or standards. Record the exact
   mechanism learned from each source and explain whether it is adopted, adapted, or
   rejected. Do not copy a local structure without understanding its contract.
3. Freeze the first implementation checkpoint in `ARCHITECTURE_PLAN.md`. A later change
   that contradicts a frozen decision needs a new decision record.
4. Put educational TODOs directly above their implementation locations. Each TODO must
   identify required declarations, defaults, state transitions, edge cases, and tests.
5. Implement one independently verifiable boundary at a time. Keep incomplete source files
   out of the active filelist so the last verified checkpoint remains runnable.
6. After verification, append the command, configuration, commit, result, and analysis to
   `EXPERIMENT_LOG.md`. Never overwrite an older result when the design changes.

## Review Standard

A module record is ready for RTL only when it answers all of these questions:

- What information does this module own, and what must remain outside it?
- What transaction starts work, what transaction ends work, and what must remain stable
  under backpressure?
- Which state is architectural, speculative, replaceable, or simulation-only?
- What happens on reset, redirect, exception, invalidation, and downstream stall?
- Which latency is required, which throughput is required, and which path may become a
  timing bottleneck?
- Which assertions detect corruption, duplication, loss, stale responses, or protocol
  violations?
- Which counters prove that the feature improves the target workload?

## Current Records

- [`ICACHE_DESIGN_RECORD.md`](ICACHE_DESIGN_RECORD.md): first cache checkpoint and its
  planned migration path toward a high-performance frontend.
- [`EXPERIMENT_LOG.md`](EXPERIMENT_LOG.md): baseline and future cache experiments.
