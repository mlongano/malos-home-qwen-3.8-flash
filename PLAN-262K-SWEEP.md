# Native 262K prefill and compaction optimization plan

**Status:** completed 2026-09-21. See [`SWEEP-262K-FINDINGS.md`](SWEEP-262K-FINDINGS.md).
The remote compaction extension remains a documented option only: not installed, not tested, no
conversation data sent remotely. Pi's default local compaction stays in effect.

## Non-negotiable constraint

Keep native context at 262,144 tokens. The winner minimizes total wall time for real Pi work:
full-prefix prefill, long-context decode and compaction. Short-context decode alone does not decide
production.

## Findings from the second review

- Latest Pi compaction metadata:
  - 246,381 tokens before compaction
  - 141,476 input tokens sent to the summarizer
  - 8,542 output tokens
  - zero reasoning tokens
  - 21,169-character, 247-line summary
- Live server timing for the same request:
  - 136,627 evaluated prompt tokens, 29.2 minutes at 77.9 t/s
  - 7,553 predicted tokens, 10.2 minutes at 12.4 t/s
  - 39.4 minutes total
- Pi deliberately gives compaction a fresh routing session and disables cache writes. The existing
  246K live KV cannot be used for the compaction request.
- llama.cpp also disables `--cache-reuse` when a multimodal projector is loaded. Chunk reuse cannot
  rescue compaction on this production server.
- `--cache-ram` remains useful for branch/reset/divergent-prompt recovery. With one non-unified
  slot, normal append turns do not copy the whole KV to host. A large copy happens only when the
  incoming prompt would discard most of the current slot.
- Target KV is q8_0, but MTP draft KV is still the f16 default. Draft KV q8_0 is a low-risk memory
  and bandwidth candidate because target verification preserves output quality; acceptance rate
  and speed still need measurement.
- Mixed K/V cache formats matter. K commonly needs more precision than V. Test q8_0 K with q4_0 V
  and q5_1 K with q4_0 V before forcing both to q4_0.
- The current CPU build is native AVX-512/OpenMP with BLAS disabled. OpenBLAS is not installed.
  A BLAS rebuild is not in the first sweep because quantized MoE kernels may not benefit and it
  would add another uncontrolled variable.
- CPU has one NUMA node and 16 physical cores plus SMT. Current governor is dynamic `powersave`,
  running near 3.6 GHz while sampled. Batch-thread count and strict physical-core pinning are valid
  test axes; changing the system governor is not authorized and is not in the plan.
- PR #28243 is still open at the pinned commit `53b1389`; no newer upstream MTP runtime currently
  replaces this build.

## Prepared before downtime

- Current process arguments: `provenance/production-args-2026-09-21.txt`.
- Pinned benchmark binary: `runtime/build-mtp/bin/llama-bench`.
- Launcher knobs added without changing the running process:
  - target `CT_K`, `CT_V`
  - draft `CT_K_DRAFT`, `CT_V_DRAFT`
  - `CACHE_RAM_MIB`, idle-slot and checkpoint controls
  - `THREADS_BATCH`, CPU ranges and strict placement
- Tools:
  - `probe-vram.sh`
  - `probe-workload.py`
  - `sweep-longcontext.sh`
  - `quality-kv-gate.py`
- Scripts parse. The quality gate's token-array and next-token probability path passed a live
  two-position dry test.

## Phase 1: checkpoint and stop production, about 5 minutes

1. Confirm this Pi session uses a non-`malos-home` model.
2. Save service state, invocation, health, VRAM/RSS, swap counters and log tail.
3. Stop `qwen38-flash-native-mtp.service`.
4. Confirm port 18080 is free and no llama-server owns GPU memory.
5. Keep DeepSeek stopped for the whole sweep.

Rollback at any phase: restart the captured q8_0 target/f16-draft, ubatch 256, CPU-MoE 34,
MTP-depth-1, vision profile.

## Phase 2: real production VRAM feasibility, 20-35 minutes

`probe-vram.sh` starts the actual server at native 262K with MTP and vision. Each candidate runs a
4,096-token text prefill, short decode and exact vision request while VRAM is sampled. Idle load
alone is not accepted. Require:

- exact `VISION 731\nYELLOW CARD`
- no load/request error
- at least 1,024 MiB free against the driver's 32,614 MiB total

Matrix:

| Name | Target K/V | Draft KV | ubatch | CPU MoE |
|---|---|---|---:|---:|
| current | q8/q8 | f16 | 256 | 34 |
| safe ubatch | q8/q8 | f16 | 512 | 34 |
| draft compression | q8/q8 | q8 | 512 | 34 |
| K-preserving 1 | q8/q4 | q8 | 512 | 30 |
| K-preserving 2 | q8/q4 | q8 | 512 | 28 |
| middle 1 | q5/q5 | q8 | 512 | 30 |
| middle 2 | q5/q4 | q8 | 512 | 28 |
| middle 3 | q5/q4 | q8 | 512 | 26 |
| compressed 1 | q4/q4 | q8 | 512 | 26 |
| compressed 2 | q4/q4 | q8 | 512 | 22 |
| compressed 3 | q4/q4 | q8 | 1024 | 22 |

q4_1 and iq4_nl are fallback formats only if q4_0 is fast but fails quality. This keeps the first
matrix bounded.

## Phase 3: broad speed and CPU screen, 35-60 minutes

Use llama-bench `-pg 32768,64` on the current baseline and up to four feasible frontier configs.
For the baseline and fastest compressed candidate, compare:

- ubatch 256 versus 512, and 1024 only when Phase 2 proves margin
- `threads-batch` 16 versus 32
- default scheduling versus strict physical-core range `0-15`
- batch size 2,048 versus 4,096 only if ubatch results indicate scheduler overhead remains

Keep generation threads at 16. Do not infer production VRAM from llama-bench because it does not
load vision or the MTP head. Phase 2 owns feasibility.

Monitor CPU frequency, GPU clocks/temperature, major faults, swap-in and NVMe reads. If prefill
shows storage faults, add one warm repeat before comparing configs. Do not switch lazy mmap off by
default; earlier controls were slower and used 36.5 GiB more RSS.

## Phase 4: long-context benchmark, 60-100 minutes

Run `-pg 100000,64` on:

1. q8/q8, f16 draft, ubatch 512, CPU-MoE 34
2. the fastest mixed-KV candidate
3. the fastest all-q4 candidate only if it differs materially from candidate 2

Metrics:

- prompt tokens/s
- generation tokens/s at 100K occupied context
- wall time and peak VRAM
- projected waits for 114K, 141,476 and 246K prompts
- projected total for 141,476 input plus 8,542 output tokens

## Phase 5: prompt-cache behavior, 15-30 minutes

Test the winning placement with a 100K prompt:

1. evaluate prompt A
2. send divergent prompt B, forcing A into host prompt cache
3. resend A and measure save/restore time
4. repeat once with `--no-cache-idle-slots`

This proves whether `--cache-ram 24576` replaces a full prefill with a seconds-scale host copy and
measures its request-transition overhead. Also compare `MemAvailable`, page-cache residency, major
faults and NVMe reads before and after saving the state: a 20 GiB host copy must not evict hot model
pages and make the following prefill slower. Keep 24 GiB only if restore works, append turns remain
cheap and storage traffic does not regress. Otherwise choose the largest measured safe limit between
16 and 24 GiB.

Context checkpoints remain at 32 unless logs show material checkpoint cost. If they do, compare 8
versus 32 on the winner. Zero checkpoints are not a production candidate because rollback and
partial-prefix reuse matter for agent sessions.

## Phase 6: quality gate, 30-70 minutes

### Control

Run q8/q8 target KV, CPU-MoE 34 against itself. Required:

- approximate top-64 KLD <= 0.000001
- top-1 agreement = 100%

A failed control blocks all compressed-KV deployment.

### Isolate KV precision

First compare candidate KV against q8/q8 at the same CPU-MoE 34. Then repeat the passing KV format
with the final expert placement. This separates cache quantization error from harmless placement
rounding.

Proposed short gate over about 1,024 teacher-forced positions:

- mean approximate KLD <= 0.01 nats
- top-1 agreement >= 98%
- record mean absolute reference-token log-probability delta

Greedy byte identity is not required.

### Real 100K production validation

llama-bench is not enough. Start the actual MTP+vision server for baseline and the final candidate.
Use the same deterministic, agent-shaped 100K prompt with exact keys near the beginning, middle and
end. In one run collect:

- real prefill t/s
- MTP decode t/s and acceptance
- exact retrieval of all keys
- target next-token log probabilities near the end
- VRAM/RSS/temperature, major faults, swap and NVMe reads
- exact image transcription after the long prompt

This run decides production. It also captures MoE routing on realistic text instead of synthetic
llama-bench tokens.

Draft-KV q8 does not need target-quality KLD, but it must preserve or improve MTP acceptance and
wall time.

## Phase 7: deploy or roll back, 10-15 minutes

Hard requirements:

- native 262,144 context
- Q4 target weights unchanged
- vision and MTP depth 1 unchanged
- HSA_ENABLE_SDMA=1
- at least 1 GiB request-time VRAM margin
- quality and 100K retrieval gates pass
- no swap-in, OOM, ROCr or SDMA error

Rank passing candidates by measured production wall time for the real compaction workload:

`141476 / prefill_tps + 8542 / long_context_decode_tps`

If compressed target KV fails, deploy the safe result if it passes Phase 2:

- target q8/q8
- draft q8/q8 if acceptance is unchanged
- ubatch 512
- CPU-MoE 34, or a faster q8 placement if one fits
- host prompt cache 24,576 MiB if Phase 5 passes

Update `RESULTS.md`, `EVIDENCE.md`, `DEPLOYMENT.md` and `summary.json`.

## Compaction redesign, items 2 and 5

Item 2 remains in scope, but the reason is summary length, not thinking in the latest run. The last
local compaction used zero reasoning tokens and still emitted 8,542 output tokens. At 12.4 t/s that
was about 11.5 minutes by API usage count. A structured 4,096-token cap can nearly halve this phase.

Pi's official `custom-compaction.ts` route will use an already-configured remote model so it does
not compete with the R9700. This sends the serialized old conversation to that provider, so it
requires explicit approval for privacy, provider quota and possible billing before installation:

1. primary: `github-copilot/gemini-3.6-flash`, 1M context
2. fallback: `opencode-go/qwen3.8-flash`, 1M context
3. call with `reasoningEffort: "off"`, `cacheRetention: "none"`, fresh session ID and
   `maxTokens: 4096`
4. preserve Pi's `firstKeptEntryId` and recent-message boundary
5. keep goals, constraints, decisions, blockers, exact paths/hashes and unfinished work
6. remove old assistant-thinking blocks before serialization except for the newest incomplete turn
7. deduplicate repeated history and truncate routine successful tool output more aggressively;
   preserve errors, test evidence and destructive-operation decisions
8. put cumulative file operations in `CompactionEntry.details` instead of reproducing giant
   `<read-files>` and `<modified-files>` sections in text
9. fall back to default compaction if the remote provider fails

Validate on a copied session branch before enabling automatic interception. Check:

- retained facts against a deterministic checklist
- summary token count and `firstKeptEntryId`
- file-operation details
- total wall time versus 39.4 minutes
- next-turn usefulness on a real coding task

Target: under five minutes, no loss of active state, and a summary small enough that context regrowth
is driven by new work rather than historical inventories.

## Time budget

A real review-quality run is 3-4 hours, not 60-90 minutes:

- checkpoint and feasibility: 25-40 minutes
- broad CPU/KV screen: 35-60 minutes
- 100K speed runs: 60-100 minutes
- cache and quality checks: 45-100 minutes
- deploy and smoke: 10-15 minutes

Stop early on hard failures. The known-good profile can be restored at every phase.
