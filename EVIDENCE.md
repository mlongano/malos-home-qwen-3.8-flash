# Evidence index

Every measurement in this project lives under `results/`. Each subdirectory holds the raw
llama.cpp log plus a JSON record with request output, timings, VRAM/temperature/RSS peaks,
swap counters and NVMe counters. This file states what each artifact proves.

Nothing here was produced by a model server left running: all evidence comes from
sequential, single-slot, loopback-bounded runs.

## Baseline and expert residency (installed runtime b11007)

| Artifact | Proves |
|---|---|
| `smoke32-lazy-on/` | First load: 32 CPU MoE layers leaves experts under-used, 3.87 t/s |
| `residency-sweep-v1/` | Q4 residency sweep 32/28/26/25/24; 26 layers is the best safe split, 24 gains nothing |
| `residency-26-v1/` | Repeat of the selected 26-layer profile |
| `residency-boundary-repeat-v1/` | Boundary placement is reproducible, not a one-off |
| `threads32-ncmoe26-v1/` | 32 logical threads collapse throughput to 1.99 t/s; 16 physical threads are correct |
| `lazy-off-ncmoe26-v1/`, `lazy-off-ncmoe26-v2/` | Lazy-mmap control: 36.5 GiB more RSS and ~33% slower median |
| `q4-native-262k-allocation-v1/` | Native 262,144-token allocation plus bounded generation, 7.61 t/s |
| `q4-yarn-1m-allocation-v1/` | 1,048,576-token allocation with static 4x YaRN, 5.27 t/s |

## IQ4 speed-only quant

Model files were removed after selection; the numbers below stay valid.

| Artifact | Proves |
|---|---|
| `iq4-residency-sweep-v1/`, `iq4-residency-boundary-v1/` | IQ4 optimum is 20 CPU MoE layers |
| `iq4-ncmoe20-512-v1/`, `iq4-ncmoe20-repeat-v1/` | Repeated short runs 9.97 / 10.49 t/s |
| `iq4-ncmoe20-ctx76k-v1/` | 76K allocated context still 9.98 t/s; allocation only, not an occupied 76K prompt |

## MTP

| Artifact | Proves |
|---|---|
| `mtp-ncmoe28-v1/` | Installed b11007 aborts before serving: `GGML_ASSERT(ggml_can_repeat(b, a))` in `llama_model_qwen4exp::graph::build_hc_mix` |
| `mtp-pr-head-32k-v1/` | Pinned PR #28243 build runs the shared Q8 head. Draft depth 1 beats depth 2. MTP output is not byte-identical to no-MTP greedy output; `--no-spec-draft-backend-sampling` does not restore parity |
| `mtp-pr-head-262k-placement-v1/` | Placement sweep at native 262K (35/33/32/29 layers). MTP depth 1 reaches 20.33 / 20.64 t/s on a predictable forced-512 sequence, 98.4% draft acceptance; the same PR runtime without MTP is 15.47 t/s median |

## Vision

| Artifact | Proves |
|---|---|
| `vision-mtp-262k-v1/test.png` | Deterministic synthetic card: `VISION 731` over `YELLOW CARD`, SHA-256 `baaf4be14ed1424c39ecb29889cf53ebc00ca566f6186ab44f8a948d0e1654e3` |
| `vision-mtp-262k-v1/result.json` | Projector + MTP coexist; transcription exact at 33 CPU MoE layers but 30,362 MiB peak VRAM |
| `vision-mtp-262k-v1/ncmoe34-result.json` | Selected placement: exact transcription, 17.88 t/s, 29,398 MiB peak |
| `vision-mtp-262k-v1/ncmoe34-min1024-result.json` | With the recommended 1,024 image-token minimum: still exact, 17.88 t/s, 29,447 MiB peak, 1,130 prompt tokens |

## Prefill micro-batch ceiling

`results/prefill-ubatch-v1/` contains the original conservative screen. The later
production-shaped probes corrected its 30,576 MiB guard against the actual 32,624 MiB card total.
With q8 target KV, MTP and vision, ubatch 512 at CPU MoE 34 peaked at 30,514 MiB in the feasibility
probe and 30,833 MiB during the real 100K request. It is selected with 1,791 MiB worst measured
free. CPU MoE 33 reached 31,798 MiB and was rejected with only 826 MiB free.

## Prompt caching and the perceived hang

| Artifact | Proves |
|---|---|
| `native-service-smoke/response.json` | First text-only production smoke, exact `READY` |
| `native-mtp-service/server.log` | The `ping` that looked stuck: 9,756 prompt tokens took 113.9 s of prefill at 85.7 t/s, then 22 tokens at 15.6 t/s. It completed |
| `native-mtp-service/cache-prompt-ab.json` | With `--cache-prompt`: first pass 5,481 tokens in 51.6 s, repeat 0.19 s with 5,477 tokens reused, a 266x reduction |
| `native-mtp-service/pi-turn-cache.json` | Agent-shaped turns: 661 tokens in 6.37 s, next turn reuses 657 and prefills 10 in 0.49 s |
| `native-mtp-service/vision-response.json` | Production endpoint transcribes the test card exactly at 19.03 t/s |

The earlier launcher passed `--no-cache-prompt`, chosen to isolate benchmarks. For an agent
that resends its whole prompt every turn that setting is fatal. It is now `--cache-prompt`.

## Cost of one compaction, from the live log

Task 15255 was a compaction request:

| Phase | Volume | Rate | Time |
|---|---:|---:|---:|
| Prefill of the re-serialized conversation | 136,627 tokens | 77.9 t/s | 29.2 min |
| Summary generation | 7,553 tokens | 12.4 t/s | 10.2 min |
| Total | | | **39.4 min** |

The prefill was a full re-prefill: the conversation already occupied 246,304 tokens in the slot,
but the compaction prompt did not share that prefix, so none of it was reused. Roughly three
quarters of a compaction is spent re-reading the conversation.

## Unit swap and the compaction watcher

| Artifact | Proves |
|---|---|
| `handoff-window-20260923-094411/` | The transient-unit-to-linked-unit swap: the report, the service state and the workload that verified it. `DEPLOYMENT.md` §"Post-swap verification" carries the result table and the two verification bugs the script had |
| `compaction-monitor-20260922/` | 10-second samples of the slot, the unit's journal and Pi's compaction entries. Its `README.md` shows the 17-minute prefill that looked like a compaction was a full-context *turn*; `compactions.md` records the compaction it later caught (`tokensBefore` 255,651); `monitor.log` holds the decode fall-off with context (13.3-13.7 t/s at ~98K, 11.9 t/s at 116K, 10.7 t/s at 156K) |

## Note on the VRAM limit used in earlier rejections

`benchmark.py` sets `VRAM_LIMIT_MIB = 30576`. That is a project guard, not the card: the driver
reports 32,614 MiB total and 29,625 MiB committed at idle with the 262K context loaded. The
`ubatch 512` peak of 30,294 MiB was rejected against that guard, yet sits 2,320 MiB below the
card's total, so it is worth revisiting now that prefill latency is the priority.

## Native 262K optimization sweep

| Artifact | Proves |
|---|---|
| `vram-probe-20260921-1651/` | Original q8 production shape; ubatch 512 fits. Missing mixed/q5 FA kernels caused f16 conversion |
| `vram-probe-20260921-1703/`, `vram-probe-20260921-1711/` | Separate mixed-FA runtime feasibility frontier with real text, MTP and vision requests |
| `screen32k-20260921-1718/`, `screen100k-20260921-1800/` | Compressed KV plus two more GPU expert layers is faster before quality gating |
| `quality-kv-gate/` | q8 control exact; all compressed target-KV candidates fail KLD/top-1 gates; q8 CPU-MoE-33 passes |
| `real100k-v1/` | Real 100,109-token A/B: 80.15 to 95.73 t/s prefill, 16.10 to 18.33 t/s decode, exact recall and vision |
| `cache100k-v1/` | 100K q8 state restored in 1.20 s with 100,000 cached tokens after divergence |
| `deploy-20260921-232158/` | Active argument list, binary hashes, health, text and exact vision smoke tests |

## Not reproduced

- Approximately 20 t/s holds only on a highly predictable sequence with MTP. General prose
  sits at 17-19 t/s.
- A genuinely occupied 262K or 1M prompt has never been run. The large-context numbers are
  allocation plus bounded generation.
- Byte-identical output between MTP and no-MTP greedy decoding has not been achieved.
  Divergence is a different valid trajectory, not a demonstrated quality loss.
