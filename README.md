# Qwen3.8 Flash Next on one R9700

Evaluation and deployment of `Qwen3.8-Flash-Next` (GGUF) on a single AMD Radeon AI PRO R9700
with 128 GiB of system RAM:

- Intel i9-7960X, 16 physical cores used, 128 GiB quad-channel DDR4-2800
- Radeon AI PRO R9700 32 GiB (32,624 MiB per driver during the latest probes); the
  30,576 MiB figure used in rejections was a project-set guard in `benchmark.py`, not the card
- model files on NVMe at `/media/NVME_DATA`

Nothing here changes Pi's installed code, Unsloth's runtime, system ROCm, or the DeepSeek
project. Models, results, the runtime build tree and logs are ignored by Git.

## Running now

```
unit      qwen-flash.service                (linked unit file, no autostart)
manager   pi-inference qwen-flash           (mode since 2026-09-23; the manager owns the switch)
systemd   systemd/qwen-flash.service        (Restart=on-failure, hardened)
endpoint  http://127.0.0.1:18080/v1         also 0.0.0.0, tailnet and LAN
alias     qwen3.8-flash-next
launcher  ./run-q4-native-mtp.sh
```

Q4 at native 262,144 tokens, 34 CPU MoE layers, Q8_0 KV, ubatch 512, CPUs 0-15 pinned, lazy
n-gram mmap, MTP draft depth 1, vision projector with a 1,024-token image minimum, and a 24 GiB
host prompt cache. A real 100K request reached 95.73 t/s prefill and 18.33 t/s decode with exact
key recall; vision transcription remains exact. See [`DEPLOYMENT.md`](DEPLOYMENT.md).

Pi uses this endpoint under two provider ids, `malos-home` and `qwen-flash`, both pointing at
`malos/qwen3.8-flash-next`. Pi resolves a provider per request, so renaming or removing one while a
session is using it breaks that turn; the second id exists for that reason.

## Results in one table

| Profile | Runtime | Decode | Note |
|---|---|---:|---|
| IQ4, 20 CPU MoE | installed b11007 | 10.54 t/s | speed-only, model files removed |
| Q4, native 262K | installed b11007 | 7.61 t/s | validated, no MTP |
| Q4, 1M + 4x YaRN | installed b11007 | 5.27 t/s | max capacity, YaRN applies to short prompts too |
| Q4, 262K, MTP depth 1 | pinned PR #28243 | 17-19 t/s prose | deployed |
| same, predictable sequence | pinned PR #28243 | 20.6 t/s | 98.4% draft acceptance, do not generalize |
| same, with vision | pinned PR #28243 | 19.03 t/s | exact transcription |
| same, real 100K prompt | pinned PR #28243 | 95.73 t/s prefill; 18.33 t/s decode | exact recall, 30,833 MiB peak |

Full detail in [`RESULTS.md`](RESULTS.md); what each measurement artifact proves is in
[`EVIDENCE.md`](EVIDENCE.md).

The ~20 t/s headline from the AtomicChat video is not reproduced as a general rate here. This
host has far more RAM than the 32 GB machine in the video but only one discrete GPU, so CPU/GPU
expert placement decides both speed and VRAM.

## Layout

| Path | Purpose |
|---|---|
| `README.md` | this file |
| `RESULTS.md` | measurements and reasoning |
| `SWEEP-262K-FINDINGS.md` | final 2026-09-21 sweep outcome and deployment decision |
| `EVIDENCE.md` | index of every artifact under `results/` |
| `PROVENANCE.md` | exact files, commits, hashes, what was removed |
| `DEPLOYMENT.md` | active service, endpoints, network exposure |
| `summary.json` | machine-readable version of the above |
| `config.env` | shared model and runtime variables |
| `download-*.sh` | fetch Q4, IQ4, MTP head, vision projector with SHA verification |
| `build-mtp-runtime.sh` | build the pinned PR runtime for `gfx1201` |
| `run-q4-native-mtp.sh` | production launcher (MTP + vision) |
| `run-q4-native-max.sh`, `run-q4-extended-max.sh` | installed-runtime fallbacks, 262K and 1M |
| `run-server.sh`, `benchmark.py` | bounded test launchers and sweeps |
| `provenance/` | manifests written by the scripts |
| `pi-extensions/` | remote compaction extension: documented option, intentionally not installed or tested |
| `UPSTREAM.md` | upstream intake: when to move the llama.cpp pin, and the ROCr dependency on `ds4` |
| `run-handoff-window.sh` | the 2026-09-23 transient-to-installed unit swap, verified and with rollback |
| `run-mtp-pr-test.sh` | what the launcher executes: every flag, the ROCr path, the guard rails |
| `sweep-longcontext.sh` | long-context relative speed sweep with the pinned `llama-bench` |
| `probe-vram.sh`, `probe-workload.py` | production-shape VRAM probe and the text/vision workload it samples |
| `quality-kv-gate.py` | teacher-forcing KLD and top-1 gate for a candidate KV cache |
| `real-longcontext-test.py`, `run-real100k.sh` | real 100K agent-shaped request harness, on its own server on port 18099 |
| `make-agent-prompt.py` | builds that harness's agent-shaped corpus from a Pi session JSONL |
| `test-prompt-cache.py` | prompt-cache save/restore check behind `results/cache100k-v1/` |
| `models/` | Q4, MTP head, projector (88 GB, ignored) |
| `runtime/` | pinned PR source clone and build tree (496 MB, ignored) |
| `results/` | raw logs and JSON evidence (ignored) |

## Commands

```sh
./run-q4-native-mtp.sh                       # production endpoint
./run-q4-native-max.sh                       # installed runtime, native 262K, no MTP
./run-q4-extended-max.sh                     # installed runtime, 1M, 4x YaRN
./benchmark.py --model-profile q4 --profiles 32 28 24 --lazy on --ctx 32768
./build-mtp-runtime.sh                       # rebuild the pinned PR runtime
```

## Controls that matter

- `--load-mode mmap --lazy-mode on` keeps the 38.4 GB n-gram shard pageable on NVMe.
- `--fit off` avoids llama.cpp's bad automatic fit for this architecture.
- `--no-op-offload` keeps CPU-resident expert math on the CPU instead of re-streaming weights.
- `--n-cpu-moe` decides the split; it dominates decode cost on this host.
- `--cache-prompt` is required for agent use. With `--no-cache-prompt` every turn re-prefills the
  whole conversation, which looked exactly like a hang.
- `--ctx-checkpoints 32 --checkpoint-min-step 8192` are in the running process and in no measurement
  under `results/`: they are the current defaults, not a conclusion. Checkpoints hold KV state of
  their own, so anyone changing them should measure. `run-server.sh` disables them
  (`--ctx-checkpoints 0`) for the YaRN profiles.
- 16 physical threads; 32 logical threads collapsed throughput to 1.99 t/s.
- `HSA_ENABLE_SDMA=1` stays enabled.

## Cleanup record

Removed after Q4 was selected: the IQ4 candidate
`Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64`, 28 shards, 84,930,924,160 bytes, first-shard
SHA-256 `7286697d1ede4318a5b40b5ef6965c4c93cb3eb8b8d5f5d415f0dd500b4677db`. That freed 79.10 GiB.
`./download-iq4.sh` refetches it and re-verifies the hash. Every IQ4 measurement is still in
`results/` and `EVIDENCE.md`.

Retained because the running service maps it: Q4 shards, the shared Q8 MTP head, the F16
projector, and the pinned PR runtime.

## Open items

- A genuinely occupied 262K or 1M prompt has not been measured, only allocation.
- The PR #28243 runtime has not been quality-evaluated against build 11007.
- MTP output is not byte-identical to no-MTP greedy output. That is a different valid
  trajectory, not a demonstrated quality loss, but upstream has not settled it.
- The model thinks by default: a trivial reply costs 32 tokens, 111 characters of it reasoning,
  against 2 tokens with `chat_template_kwargs: {"enable_thinking": false}`. If replies feel
  verbose, the knobs are thinking on/off and output budget. Too small a budget returns empty
  `content` with `finish_reason: length`.

## Related projects

The manager, the panel and the design record live in
`~/Develop/MACHINE_LEARNING/local-models`: `QWEN_FLASH_CONTROL_PLANE.md` (why this is a mode rather
than a `pi-llama` router model, the lease and occupancy rules, the phases still open) and
`QWEN_FLASH_HANDOFF.md` (the executed handoff window). This repo depends on the `ds4` project for
one thing it cannot regenerate locally, the patched ROCr prefix; `UPSTREAM.md` documents it, and
`DEPLOYMENT.md` §"Coexistence" records what that means in practice. The `ds4` engine is not an
alternative for this model on this host either: as of 2026-09-16 its upstream carries Qwen3.8 Flash
Next for Metal and CUDA but not for ROCm (`ds4/docs/SESSION_SUMMARY_2026-09-04_2026-09-17.md`),
which is part of why this runs on a pinned llama.cpp PR.

## Sources

- AtomicChat package: <https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF>
- AtomicChat running guide: <https://atomic.chat/blog/guides/how-to-run-qwen-3-8-flash-next-locally>
- Upstream lazy tensor loader: <https://github.com/ggml-org/llama.cpp/pull/27794>
- llama.cpp PLE SSD discussion: <https://github.com/ggml-org/llama.cpp/discussions/27864>
- Qwen3.8 MTP pull request: <https://github.com/ggml-org/llama.cpp/pull/28243>
- Unsloth Qwen3.8 MTP guidance: <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/blob/main/MTP/README.md>
