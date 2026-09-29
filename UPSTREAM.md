# Upstream intake

How to move the llama.cpp pin and judge whether a newer PR head is worth it. The running
service's exact shape: `DEPLOYMENT.md`. What every measurement proves: `EVIDENCE.md`.
This file is only about upstream.

## Where we stand

- Upstream: llama.cpp PR #28243 (unmerged) — <https://github.com/ggml-org/llama.cpp/pull/28243>.
  We run the PR head, not master: native MTP (depth 1, shared Q8_0 head, backend sampling)
  exists only there, which is also why no Unsloth Studio build can produce this runtime.
- Checkout: `runtime/llama.cpp-mtp` (partial clone of `ggml-org/llama.cpp`). Build:
  `runtime/build-mtp`. `build-mtp-runtime.sh` refuses to build anything but `PIN` on a clean
  tree, and records provenance (`provenance/mtp-runtime-version.txt`, `mtp-runtime-sha256.txt`).
- The crash this pin exists to dodge is also reported upstream: `unslothai/unsloth#11219`, the same
  assertion as `#11143` (`GGML_ASSERT(ggml_can_repeat(b, a))` in
  `llama_model_qwen4exp::graph::build_hc_mix`). Closed 2026-09-21 as fixed, with the interim advice
  to pin `UNSLOTH_LLAMA_RELEASE_TAG=b10909-mix-bea84f7`. Read it before assuming no Studio build can
  serve this head: what we run is the PR, not the only runtime that might work now. The thread also
  reports ~0.10 native-MTP acceptance on the installed build, which is a different question from our
  67-98% on the PR build.
- Current pin: `53b1389d0bf98fa367e2a0ce0475008e762ebf28` (2026-09-18). Distrust this line and
  refresh first:

  `git -C runtime/llama.cpp-mtp fetch origin refs/pull/28243/head && git -C runtime/llama.cpp-mtp log --oneline 53b1389d0bf98fa367e2a0ce0475008e762ebf28..FETCH_HEAD`

## Hard constraints (must survive any upgrade)

| Constraint | Value | Why |
|---|---|---|
| MTP | depth 1, shared Q8_0 head, `MTP_BACKEND_SAMPLING=1` | the reason the PR exists |
| CPU MoE layers | 34 | residency sweep in `EVIDENCE.md` |
| Threads | 16, pinned CPUs 0-15 | 32 logical collapses throughput to 1.99 t/s |
| KV | Q8_0 K/V, draft KV f16 | measured memory policy |
| Batches | 2048 / 512 micro | prefill ceiling evidence |
| Context | 262,144 native | the product feature |
| Prompt cache | 24,576 MiB host budget | live conversations live here |
| Vision | on, min image tokens 1,024 | production vision request evidence |
| Alias | `qwen3.8-flash-next` | Pi and Studio provider configs name it |
| Toolchain | `gfx1201`, project-local ROCr from `../ds4/misc/rocm-local-runtime-fixed-prefix/lib` | cross-project dependency and a single point of failure — see the next section |

## The ROCr prefix is a single point of failure

The runtime loads a project-local ROCr built from a patched source tree that exists in one place.
Nothing in this project can regenerate it.

| What | Where |
|---|---|
| Patch | `../ds4/rocm/patches/0001-rocr-wrap-final-sdma-tracker-half-word.patch` — `ROCm/rocm-systems`, six lines in `amd_blit_sdma.h`, commit `1a2897e7ad`, branch `ds4-sdma-pendingbytes-wrap-fix` (local name, on no remote, not an ancestor of `rocm-7.2.4`) |
| Built prefix | `../ds4/misc/rocm-local-runtime-fixed-prefix/lib` — under `misc/`, which `ds4/.gitignore:42` excludes, so it has no history and no remote copy |
| Stable copy | `~/.local/opt/rocr-r9700/lib` (built 2026-09-19), outside both repositories, with the patch and its README beside it |

Why it matters here:

- `run-mtp-pr-test.sh` refuses to start without `libhsa-runtime64.so.1` and puts the prefix on
  `LD_LIBRARY_PATH`, after the runtime's own `bin`. Losing the directory stops `pi-inference
  qwen-flash` from starting at all.
- `sweep-longcontext.sh` resolves it the same way and now refuses instead of quietly falling back to
  the system ROCr: a sweep against an unpatched runtime would report numbers that do not describe
  production. That was its behaviour until 2026-09-29.
- `run-server.sh` does not use the prefix; it runs the installed Unsloth build.

The `ds4` side documents the same directory as a published interface — `../ds4/docs/UPSTREAM.md`:
never move or delete it in a change that does not move this launcher in the same one. That is the
same rule from the other end.

The launchers resolve it in this order: `$FIXED_ROCR` if set, the `ds4` path if readable, the stable
copy if readable, then refuse. Moving or deleting the `ds4` directory is still a cross-project
change: repoint every launcher in the same commit. And never run `git clean -x` in `ds4` — `x`
deletes ignored files, which is all of `misc/`.

The stable copy is not a frozen binary either: the patch it needs is in git
(`ds4/rocm/patches/`), and upstream tag `rocm-7.2.4` plus that patch rebuilds it (recipe and compiler
version in `ds4/rocm/patches/README.md`). The SHA-256 here identifies the binary in use, so a rebuild
has to re-record it in this file and in `PROVENANCE.md`.

## Deciding whether to move the pin

A newer head is worth taking only if it does at least one of:

- fixes a bug or misbehaviour we have recorded (`EVIDENCE.md`, e.g. the prompt-cache hang),
- improves measured decode/prefill **on the same scenario** as a `results/` baseline without
  regressing the other rows of the `EVIDENCE.md` tables,
- upstreams part of the constraint list, so the pin carries less weight.

Evidence protocol: same scenario, same `config.env` values, run kept under `results/` in the
established shape (raw llama.cpp log + JSON with timings, VRAM/temperature/RSS peaks, swap
and NVMe counters). Compare per scenario only — never against a number from a different
scenario or a different quant.

Completion criterion: a written verdict (move/skip) naming the numbers compared against the
`results/` artifacts, before any rebuild happens.

## Moving the pin

1. **Baseline.** `pi-inference status` shows mode `qwen-flash` and a healthy service; the
   evidence you will compare against is identified. → complete when: those baselines are
   named in the verdict.
2. **Verdict.** Fetch and decide per the section above. → complete when: written verdict
   exists.
3. **Pin.** Edit `PIN` in `build-mtp-runtime.sh` and the commit line in `DEPLOYMENT.md`
   together — the script enforces the pin, the doc is the human record. → complete when:
   both name the same commit.
4. **Build.** Save the old runtime first
   (`cp -a runtime/build-mtp runtime/build-mtp-<old-pin-short>`), then
   `./build-mtp-runtime.sh`. → complete when: it exits 0 and `provenance/` shows the new
   build and hashes.
5. **Restart and measure.** Restarting discards the resident prompt cache (24 GiB budget; a
   full re-prefill of a 250K-token conversation takes ~45 min), and the manager refuses to
   switch away while a request is in flight — schedule the restart, do not surprise it.
   `pi-inference qwen-flash`, then the benchmark runs. → complete when: new artifacts are in
   `results/` and every constraint in the table above is confirmed still true.
6. **Record.** A line per artifact in `EVIDENCE.md` stating what it proves. → complete when:
   the evidence index reads cold for the new runtime.

## Rollback

Set `PIN` back to the previous commit (in `provenance/` and `DEPLOYMENT.md` history), rebuild
with `./build-mtp-runtime.sh`, `pi-inference qwen-flash`. Or copy the saved
`runtime/build-mtp-<old-pin>` back over `runtime/build-mtp`. Model files are untouched.

## When to stop and ask

- The PR rewrites MTP, slot, or cache handling so the constraint table cannot be mapped onto
  the new code with confidence.
- A rebuild would land on the live card while conversations sit in the prompt cache and the
  re-prefill cost is not acceptable right now.
- The ROCr prefix has moved, or the patch is no longer in `ds4/rocm/patches/`: that is a
  cross-project change, and both launchers here have to be repointed in the same one.
