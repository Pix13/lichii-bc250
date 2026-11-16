# Shared JIT code between emulated cores (v16 work in progress)

## Why

Each of the six emulated CPU cores has its own dynarmic `A64::Jit`: its own code buffer
(`BlockOfCode`, 512 MiB reserved), emitter tables (block descriptors, patch locations, exit
stubs, fastmem patch info, block ranges) and fast-dispatch table. They all translate the same
game code. Measured in Ocarina of Time:

- 73% of compiles repeat a block another core already has (castle route, 2026-11-13).
- After a 90-100 minute session: translated code ~1.0 GB and translator tables ~0.7 GB
  (heaptrack, play17; smaps, play16/play18), growing as new areas are visited and never freed.

One shared copy should save roughly 1 GB late in a session and most of the compile work in new
areas.

## What ties emitted code to one core today

1. `conf.callbacks` (the core's `UserCallbacks` object) is baked into every callback call as an
   immediate `this` (`Devirtualize<...>(conf.callbacks)` -> `ArgCallback`): memory read/write
   fallbacks, exclusive writes, SVC, exceptions, cache operations, CNTPCT, ticks.
2. `conf.tpidr_el0` / `conf.tpidrro_el0` pointers are baked as immediates (a64_emit_x64.cpp).
3. Exclusive-monitor pointers for this core (`GetExclusiveMonitorAddressPointer/ValuePointer(
   global_monitor, processor_id)`) and the "clear the other cores" loop that skips
   `processor_id` (emit_x64_memory.h / .cpp.inc).
4. The run-code prelude (`GenRunCode`) calls `GetCurrentBlockThunk` with the core's
   `Jit::Impl*` and the ticks callbacks with the core's `conf.callbacks`.
5. Each Jit has its own `BlockOfCode`, emitter and tables; compilation is unsynchronised.

## Plan

Phase 1, core-agnostic code (still one cache per core, behaviour unchanged):
- Add per-core fields to `A64JitState` (reached through r15 in all emitted code): the
  callbacks object, the `Jit::Impl`, tpidr pointers, the exclusive-monitor address/value
  pointers and the processor id.
- Emit those as loads from `[r15 + offset]` instead of immediates (a state-based callback kind
  next to `ArgCallback`; the function pointer stays an immediate, every core has the same
  callbacks class).
- Check: the same block compiled on two cores gives the same bytes apart from relative branches.

Phase 2, one shared cache:
- One `BlockOfCode` + `A64EmitX64` + tables shared by all A64 Jits that use the same page
  table and config; a global compile lock (cores mostly compile different blocks only at
  startup and in new areas).
- Fast-dispatch tables and RSBs stay per core (they only hold pointers into the shared code).
- Block linking patches shared code that other cores may be running: patch only aligned
  jump slots with single atomic stores, or keep linking per-core-safe.
- Invalidation (`InvalidateCacheRange`, full flushes) becomes stop-the-world: every core is
  halted before code is removed, then all fast-dispatch tables are cleared.
- The fastmem fault handler looks blocks up in the shared tables.

Phase 3, testing: castle and Hyrule routes, then a long owner session with the memory recorder.
Keep a switch (`EDEN_NX2_SHARED_JIT=0`) to fall back to per-core caches.
