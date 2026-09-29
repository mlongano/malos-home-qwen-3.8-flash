# Initial results — 2026-09-20

## Native 262K optimization update — 2026-09-21

The deployed quality-preserving profile now uses q8_0 K/V, f16 draft KV, CPU MoE 34, ubatch
512, 16 physical cores pinned strictly to CPUs 0-15, and a 24,576 MiB host prompt cache. MTP,
vision, native 262,144 context and the selected Q4 model are unchanged.

A real 100,109-token agent-shaped OpenAI request produced exact three-key recall:

| Profile | Prefill | Decode | Peak VRAM | Free VRAM | Exact recall |
|---|---:|---:|---:|---:|---|
| Previous, warmed: ub256, no pinning | 80.15 t/s | 16.10 t/s | 29,722 MiB | 2,902 MiB | yes |
| Deployed: ub512, CPUs 0-15 pinned | **95.73 t/s** | **18.33 t/s** | 30,833 MiB | 1,791 MiB | yes |
| Faster placement: CPU MoE 33 | 96.68 t/s | 18.06 t/s | 31,798 MiB | 826 MiB | yes, but rejected |

The deployed profile improves warmed 100K prefill by **19.4%** and decode by **13.9%**. The
CPU-MoE-33 profile was rejected because its real request peak missed the required 1 GiB margin.
The synthetic vision card still transcribes exactly.

Compressed target KV was faster but failed the agreed teacher-forcing gate. The q8/q8 control
was exact; q5/q5 reached KLD 0.04087 and 94.43% top-1, while q4/q4 reached KLD 0.06795 and
91.31% top-1. Both are rejected. q8/q8 with CPU MoE 33 passed at KLD 0.00546 and 98.24% top-1,
but still failed the VRAM margin above.

The 24 GiB prompt cache was exercised with a real 100,000-token q8 state. After a divergent
request, all 100,000 tokens restored in **1.20 seconds**; only four prompt tokens were evaluated.
The first pass took 1,041.8 seconds. Peak process RSS was 48,127 MiB.

## Conclusion

The lazy-mmap approach works on this host. The installed Unsloth build did not reproduce the video's approximately 20 t/s, but a project-local build of the open Qwen3.8 MTP pull request reached 20.33–20.64 t/s on a predictable 512-token sequence. General prose was slower at roughly 17–19 t/s, so 20 t/s is a favorable-workload result rather than universal throughput.

Two answers to “best encoding” are needed:

1. **Best quality/capacity choice: AD-4.27bpw-Q4_K_M-M64.** AtomicChat reports KLD 0.0842 and 89.49% BF16 top-1 agreement, effectively tied with its 17.6 GB larger Q5 build. The safe local profile reached about 7.5 t/s.
2. **Fastest measured choice: AD-3.84bpw-IQ4_XS-M64.** The safe local profile reached 9.97 and 10.49 t/s in repeated 128-token runs and 10.54 t/s over a 477-token completion. Its published quality is materially lower: KLD 0.2277 and 82.68% top-1 agreement.

Use Q4 for model quality. Use IQ4 only when the roughly 36% local decode gain matters more than its documented quality loss.

## Q4 context capacity

Both advertised Q4 context tiers allocate and generate successfully:

| Mode | Context allocation | CPU MoE layers | Decode t/s | Peak VRAM MiB | Peak RSS MiB |
|---|---:|---:|---:|---:|---:|
| Native, quality-first | 262,144 | 29 | 7.61 | 29,615 | 53,581 |
| Extended, 4× YaRN | 1,048,576 | 48 | 5.27 | 23,789 | 54,552 |

The native profile is the default recommendation because it preserves native positional behavior. The absolute maximum profile uses static 4× YaRN, keeps every MoE expert layer in RAM, and is slower. Static YaRN may affect short-context quality, so use the 1M profile only for workloads that need more than 262K. These are allocation plus bounded-generation checks, not fully occupied 262K or 1M prompt tests.

Launchers:

```sh
./run-q4-native-max.sh
./run-q4-extended-max.sh
```

## Machine

- Intel i9-7960X: 16 physical cores / 32 threads
- 8 × 16 GiB DDR4-2800 across the X299 quad-channel controller
- Radeon AI PRO R9700 32 GiB
- PCIe 3.0 x16
- WD_BLACK SN7100 NVMe
- Validated baseline: Unsloth llama.cpp build 11007, commit `2d2611479`, ROCm/HIP
- Experimental MTP runtime: upstream PR #28243 build 11048, commit `53b1389d0bf98fa367e2a0ce0475008e762ebf28`, built for `gfx1201`

## Q4 residency sweep

All rows use 32K allocated context, lazy mmap, Q8 KV, 16 CPU threads, no MTP and 128 generated tokens.

| CPU MoE layers | Decode t/s | Peak VRAM MiB | Peak RSS MiB | Result |
|---:|---:|---:|---:|---|
| 32 | 3.87 | 22,657 | 53,971 | slow |
| 28 | 6.72 | 26,524 | 53,971 | safe |
| 26 | 7.31 / 7.69 | 28,449 / 28,430 | 53,971 / 53,972 | selected Q4 profile |
| 25 | 6.63 | retained in raw result | retained in raw result | no gain |
| 24 | 7.65 | 30,354 | 53,971 | rejected: about 220 MiB below watchdog limit |

Using 32 logical CPU threads reduced the 26-layer profile to 1.99 t/s. Sixteen physical-core threads are retained.

## Lazy mmap A/B

Identical Q4, `n-cpu-moe=26`, 32K allocation and exact 128-token output hash `b813566dd7130e00c2f332e2a89ae918d424118ec8054e62ca00c2145e3754e5`:

| Mode | Decode samples | Median t/s | Peak RSS |
|---|---|---:|---:|
| lazy on | 7.31, 7.69 | 7.50 | about 53.97 GiB |
| lazy off | 4.91, 6.36 | 5.64 | about 90.5 GiB |

Lazy mmap reduced RSS by about 36.5 GiB and improved median decode by about 33% in this bounded pair. System-wide swap-outs were zero during each measured request. The n-gram shard is therefore genuinely useful on this host.

## Exact video quant: IQ4

All rows use lazy mmap, Q8 KV, 16 threads and no MTP.

| CPU MoE layers | Decode t/s | Peak VRAM MiB | Note |
|---:|---:|---:|---|
| 32 | 5.07 | 19,271 | too much expert work on CPU |
| 28 | 7.86 | 22,373 | safe |
| 24 | 6.25 | 25,469 | no gain on this token stream |
| 22 | 9.30 | 27,032 | safe |
| 20 | 9.97 / 10.49 | 28,575 / 28,584 | selected IQ4 profile |

A 477-token completion sustained 10.54 t/s with 28,585 MiB peak VRAM and 44,822 MiB peak RSS. It completed normally at EOS with no watchdog fault. A short prompt under a 76,000-token allocation reached 9.98 t/s and 29,341 MiB VRAM. This is **not** an occupied 76K-context result; a real 76K prompt remains a separate long test.

## MTP

The installed Unsloth build 11007 still aborts before serving with the recommended shared Q8 head:

```text
GGML_ASSERT(ggml_can_repeat(b, a)) failed
llama_model_qwen4exp::graph::build_hc_mix
```

That failure is retained in `results/mtp-ncmoe28-v1/`. A project-local ROCm build of the exact current head of upstream PR #28243, commit `53b1389d0bf98fa367e2a0ce0475008e762ebf28`, resolves the graph failure. Build hashes are in `provenance/mtp-runtime-sha256.txt`; source and build trees are ignored under `runtime/`.

At native 262K allocation, Q8 KV and 16 threads:

| PR runtime profile | CPU MoE | Decode result | Peak VRAM MiB | Note |
|---|---:|---:|---:|---|
| No MTP control | 29 | 15.47 t/s median; 15.74 t/s forced-512 | 29,524 | fastest safe no-MTP placement tested |
| MTP depth 1 | 33 | roughly 17–19 t/s general prose | 29,182 | 67% acceptance on the prose prompt |
| MTP depth 1 | 33 | 20.33 / 20.64 t/s forced-512 | 29,188 | 253/257 drafts accepted |
| MTP depth 2 | 33 | 16.75 / 16.90 t/s | 29,300 | slower on this split |
| MTP depth 1 | 32 | 18.04 / 19.02 t/s | 30,151 | rejected for narrow margin |

The forced-512 comparison gives a 29–31% MTP gain over the same PR runtime's optimized no-MTP profile. It is an intentionally predictable integer sequence and reached the token cap; it must not be generalized to arbitrary prose.

MTP repeated deterministically within each configuration, but its greedy output was not byte-identical to no-MTP output. Draft depth 1 and disabling backend draft sampling did not restore parity. The no-MTP PR runtime also differs from build 11007, so the runtime itself requires separate quality acceptance. Upstream PR #28243 remains open; its ROCm CI passes, but token-by-token losslessness has not been established here.

The assertion that blocked the installed runtime is reported upstream as `unslothai/unsloth#11219`
(the same one as `#11143`) and was closed as fixed on 2026-09-21. `UPSTREAM.md` keeps the lead and
the interim `b10909-mix` pin, because a newer Studio build may now serve this head without the PR.

Evidence:

- `results/mtp-pr-head-32k-v1/`
- `results/mtp-pr-head-262k-placement-v1/`

## Vision

The exact AtomicChat F16 projector, SHA-256 `0e61454a76dd154a10aaa8fb1ada32615f55a13e4171014dacd06913e4aa6889`, loads successfully alongside the Q4 base and shared Q8 MTP head. A synthetic image containing `VISION 731` and `YELLOW CARD` was transcribed exactly.

The 1,024-token image minimum is not a preference. llama.cpp warns at load that "Qwen-VL models
require at minimum 1024 image tokens to function correctly on grounding tasks", which is why the
launcher passes `--image-min-tokens 1024`; the same number sets the floor on what one image costs in
prefill.

The original 33-layer placement peaked at 30,362 MiB VRAM and was rejected for narrow margin. Moving one more MoE layer to CPU produced the selected profile:

| Context | CPU MoE | Image minimum | Decode | MTP acceptance | Peak VRAM MiB |
|---:|---:|---:|---:|---:|---:|
| 262,144 | 34 | 1,024 tokens | 17.88 t/s test; 19.03 t/s production | 22/23 | 29,447 |

The production endpoint advertises `multimodal`. Pi lists the model with image support, and its documented `@image` command reproduced the exact transcription. Evidence is under `results/vision-mtp-262k-v1/` and `results/native-mtp-service/`.

## Prompt caching

The launcher originally passed `--no-cache-prompt`, which was the right choice for isolated
benchmarks and the wrong choice for serving. A Pi request appeared to hang for minutes: it was
prefilling 9,756 tokens at 85.7 t/s, taking 113.9 s, then decoding 22 tokens at 15.6 t/s. The
request finished normally; there was no fault.

Switching to `--cache-prompt` fixes repeat cost for prefixes below the prompt-cache ceiling
(see the next section):

| Request | Prefill | Cached tokens |
|---|---:|---:|
| First, 5,481 tokens | 51.6 s | 0 |
| Repeat, same prefix | **0.19 s** | 5,477 |

That 266x applies to a 5,481-token prefix. It does not extend to large conversations, which are
not cached at all - see the next section.

Agent-shaped turns behave the same way: 661 tokens in 6.37 s, then the next turn reuses 657 and
prefills only 10 new tokens in 0.49 s.

First-turn cost is unchanged and is a hardware property, not a caching bug: roughly one minute
per 6,000 tokens with 34 expert layers resident in CPU RAM.

### The model thinks by default

Qwen3.8 Flash Next emits `reasoning_content` on every reply unless thinking is turned off. A
request that only needed the token `OK` used 32 completion tokens, 111 characters of it reasoning.
With `chat_template_kwargs: {"enable_thinking": false}` the same request used 2 tokens.

Two consequences:

- A small `max_tokens` can return empty `content` with `finish_reason: length`, because the
  reasoning consumed the budget. This was reproduced at 48 tokens on a vision request that
  otherwise transcribed perfectly at 96 tokens.
- Long agent answers are partly thinking tokens. That is the honest explanation for verbose
  replies, and the knob is thinking on/off plus output budget, not temperature.

## Long-context cost model, measured from the live service

The running service logs every request. Across 74 logged turns:

| Prompt tokens | Prefill | Prefill t/s | Decode t/s | Total context |
|---:|---:|---:|---:|---:|
| 45,579 | 8.4 min | 90.7 | 15.44 | 46,150 |
| 136,627 | 29.2 min | 77.9 | 12.37 | 144,180 |
| 205,386 | 43.3 min | 79.0 | 10.06 | 206,191 |
| 209,480 | 46.3 min | 75.4 | 9.52 | 209,944 |

- 65 append turns averaged **8.7 s** each, because a continuing conversation only sends its
  delta and the slot already holds the prefix.
- Total prompt processing in the log: 148.1 minutes. Three full-history prefills account for
  118.8 of those minutes, 80% of all wall time.
- Rule of thumb on this host: **about 13 seconds per 1,000 prompt tokens**, roughly 4,700 tokens
  per minute of ingestion.

Pi compacts at `contextWindow − reserveTokens`, so this model auto-compacts at 262,144 − 16,384 =
**245,760 tokens** unless the 16,384 default is changed in `~/.pi/agent/settings.json`. One
compaction from the log cost 39.4 minutes (`EVIDENCE.md`), and nothing about it can be cached:
Pi gives compaction a fresh routing session, and llama.cpp disables `--cache-reuse` while a
multimodal projector is loaded (`PLAN-262K-SWEEP.md`). `results/compaction-monitor-20260922/`
sampled the slot every 10 seconds around this: decode 13.3-13.7 t/s at ~98K context, 11.9 t/s at
116K, 10.7 t/s at 156K.

### Why prefix caching silently stops working

KV state is **81 KiB per token** (19,914 MiB for a 246,304-token conversation). llama.cpp caps
the prompt cache at `--cache-ram`, whose upstream default is **8192 MiB**, so the ceiling is
about **104,000 tokens**. Above it the server logs and gives up:

```
W srv alloc: - prompt state size 19914.243 MiB exceeds cache size limit 8192.000 MiB, skipping
```

Both large states in the log were skipped. Consequences:

- Small prefixes get evicted to make room for other small prefixes (`removing oldest entry
  (size = 3301.028 MiB)`), while the one context that needed caching was never cached.
- Any event that resets or diverges the slot - restart, branch, a second session sharing a long
  prefix, overflow recovery - costs a full re-prefill rather than a memory copy.
- The two 205k/209k prefills were the same conversation with 4,094 more tokens. Recomputing cost
  46 minutes; the shared prefix was thrown away.

### The ceiling is host RAM, so it is cheap to raise

`server_prompt_cache::alloc` stores state in `std::vector<uint8_t>` buffers moved into
`llama_state_seq_get_data_ext` / `set_data_ext`. That is **host memory, not VRAM**. This box has
83 GiB free, and a full 262,144-token conversation needs about 20.3 GiB of it. Restoring 20.9 GB
over PCIe takes a couple of seconds at the very least (12 GB/s would be 1.7 s), against 52 minutes
of recomputation. `run-mtp-pr-test.sh` now passes `--cache-ram ${CACHE_RAM_MIB:-24576}`; it takes
effect at the next restart. The limit also shrinks itself if allocation fails, so it is not a
route to an OOM.

### Why decode also slows down

At 209,944 tokens the KV to attend over is about 16.3 GiB, so every generated token must stream
that much from VRAM. At the R9700's bandwidth that is roughly 33 ms of the observed 105 ms per
token, which is why decode falls from 19-20 t/s at short context to 9.5 t/s at 210k. Halving KV
size would attack both this and the cache ceiling.

### Measured headroom

Idle with the 262K context loaded: 29,625 MiB VRAM used of 32,614 MiB, process RSS 51.3 GiB,
83 GiB host RAM available. There is roughly 3 GiB of VRAM left and a lot of host RAM. Note
`current_link_speed` reports 32.0 GT/s on the amdgpu port, which this X299/PCIe 3.0 platform
cannot actually deliver, so treat the transfer estimate as conservative rather than verified.

## Prefill micro-batch ceiling

The earlier 30,576 MiB project guard was conservative; the card reports 32,624 MiB during the
new probes. Production-shaped requests including MTP and vision revised the decision:

| Profile | Request-time peak | Free VRAM | Verdict |
|---|---:|---:|---|
| q8/q8, CPU MoE 34, ubatch 256 | 29,555 MiB | 3,069 MiB | safe control |
| q8/q8, CPU MoE 34, ubatch 512 | 30,514 MiB probe; 30,833 MiB real 100K | 1,791 MiB worst measured | **selected** |
| q8/q8, CPU MoE 33, ubatch 512 | 31,798 MiB real 100K | 826 MiB | rejected by margin |
| q8/q8, ubatch 1,024 | above 32 GiB | insufficient | rejected |

On the real warmed 100K A/B, ubatch 512 plus physical-core pinning improved prefill from 80.15 to
95.73 t/s. Evidence is in `results/vram-probe-*` and `results/real100k-v1/`.

## Exposure and Pi integration

The server binds `0.0.0.0:18080` at the user's request. It has no API key and allows all CORS
origins, so any peer permitted by the host firewall can submit requests. Verified reachable on
loopback, the Tailscale IPv4 address, the MagicDNS name, and both LAN addresses.

`tailscale serve` was not used: Serve is disabled on this tailnet. A tailnet-only `socat`
proxy was tried first, then removed once direct binding was chosen.

Pi registers the endpoint as provider `malos-home`, model id `malos/qwen3.8-flash-next`, display
name "Malo's Qwen3.8 Flash Next Q4 MTP", with text and image input, 262,144 context and 65,536
maximum output tokens. llama.cpp accepts the `malos/` prefixed model id even though it reports
its own alias in responses, so no server-side rename was required. A second provider id,
`qwen-flash`, is a copy of that entry added on 2026-09-23: Pi resolves a provider per request, so
renaming the id under a running session would have broken its next turn. Both point at this
endpoint (`summary.json`).

## Why the video number differs

The video uses two NVIDIA GPUs and a different CUDA topology. On this one-R9700 host, the installed runtime tops out near 10.5 t/s with IQ4. The pinned MTP PR can reach about 20.5 t/s with Q4 when prediction acceptance is exceptionally high, while general prose remains around 17–19 t/s. CPU/GPU expert placement still materially affects both speed and VRAM.

## Remaining optional checks

- Actual approximately 76K-token occupied prompt, expected to require a long prefill.
- Quality evaluation and longer stability testing for the pinned PR runtime before it replaces the validated build.
- Re-test MTP when PR #28243 lands or explicitly addresses deterministic greedy divergence.

## Cleanup

The IQ4 model was removed after Q4 was selected on published quality. Its identity is recorded
in `PROVENANCE.md` and `./download-iq4.sh` still fetches it. See `EVIDENCE.md` for what every
retained artifact proves.
