# Provenance

## Runtime

- Path: `/home/mauro/.unsloth/llama.cpp/build/bin/llama-server`
- Version: `0.4.1-dev`, build `11007`, commit `2d2611479`
- Builder: Unsloth, Clang 23, ROCm/HIP
- `llama-server` SHA-256: `327472d87793f054afbfe6aafcd75803ced570a3d83a353aa5766d0edd285386`
- `libllama-server-impl.so` SHA-256: `6c0bbf6733002286ae98c4f9022c30cb0c30ae97b10bb2eefff60adaff2a15ec`
- `libllama.so.0` SHA-256: `aaed9c485c66aa22f087531b042d3a2fd92e9ac6406426d4fd35d49d13c66ea2`

The runtime advertises `--load-mode`, `--lazy-mode`, `--n-cpu-moe`, `--no-op-offload`, Q8 KV caches and Qwen3.8/Qwen4 experimental model support. The older Pi runtime, build 10068, does not advertise lazy mode and is not used.

## Experimental MTP runtime

- Source: `ggml-org/llama.cpp`, pull request `#28243`
- Pinned commit: `53b1389d0bf98fa367e2a0ce0475008e762ebf28`
- Version: `0.4.1-dev`, build `11048`
- Target: ROCm/HIP `gfx1201`
- Build script: `build-mtp-runtime.sh`
- Source/build location: ignored `runtime/`
- Binary hashes: `provenance/mtp-runtime-sha256.txt`, version stamp `provenance/mtp-runtime-version.txt`
- Project-local ROCr SHA-256: `1009e6f51ba351bf632867effc63bb0a30de2b17539b46a6150de781d0c3ec9f`

This runtime is experimental. It resolves the installed runtime's MTP graph assertion, but PR #28243 remains open and MTP did not preserve byte-identical greedy output in local testing.

The 2026-09-21 sweep also built a separate, non-deployed `runtime/build-mtp-fa-mixed/` from the
same commit with q8/q4, q5/q5 and q5/q4 FlashAttention kernels. Its hashes and version are in
`provenance/mtp-runtime-mixed-fa-sha256.txt` and `provenance/mtp-runtime-mixed-fa-version.txt`.
It exists only to evaluate compressed KV; production remains on `runtime/build-mtp/` because all
compressed target-KV candidates failed the quality gate.

## ROCr runtime

This runtime resolves `libhsa-runtime64.so.1` from a project-local prefix rather than from system
ROCm: `../ds4/misc/rocm-local-runtime-fixed-prefix/lib`, SHA-256
`1009e6f51ba351bf632867effc63bb0a30de2b17539b46a6150de781d0c3ec9f`. It is built from a
one-commit patch to `ROCm/rocm-systems` that exists only in that project:
`ds4/rocm/patches/0001-rocr-wrap-final-sdma-tracker-half-word.patch`, commit `1a2897e7ad`, on no
remote branch and not an ancestor of `rocm-7.2.4`. That prefix sits under `misc/`, which `ds4`
gitignores, so it has no history of its own. `UPSTREAM.md` §"The ROCr prefix is a single point of
failure" lists the paths, the stable copy at `~/.local/opt/rocr-r9700/` and what this service does
without it.

## Vision projector

- Repository: `AtomicChat/Qwen3.8-Flash-Next-GGUF`
- File: `mmproj-Qwen3.8-Flash-Next-F16.gguf`
- Size: 904,003,840 bytes
- SHA-256: `0e61454a76dd154a10aaa8fb1ada32615f55a13e4171014dacd06913e4aa6889`
- Download script: `download-vision.sh`

The projector comes from the same publisher and model repository as the Q4 base rather than another conversion. It passed direct OpenAI-compatible and Pi `@image` requests with MTP enabled. Manifests: `provenance/mmproj.sha256`, `provenance/mmproj-file.txt`.

## Removed after selection

The speed-only IQ4 candidate was downloaded, measured, and then deleted once Q4 was chosen on
published quality. Its identity is kept so the decision stays auditable and the files stay
reproducible with `./download-iq4.sh`:

- Variant: `Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64`
- Shards: 28
- Size: 84,930,924,160 bytes
- First-shard SHA-256: `7286697d1ede4318a5b40b5ef6965c4c93cb3eb8b8d5f5d415f0dd500b4677db`
- Published quality: KLD 0.2277, BF16 top-1 agreement 82.68%, perplexity ratio 1.102
- Measured peak: 10.5445 t/s over a 477-token completion at 28,585 MiB VRAM

The rejected MTP attempt under the installed runtime left no artifacts beyond
`results/mtp-ncmoe28-v1/`; the shared Q8 head is retained because the pinned PR runtime uses it.

## Manifests

Downloaders and the runtime build script write their manifests into `provenance/`:

| File | Producer | Content |
|---|---|---|
| `model-files.txt` | `download-model.sh` | Q4 shard names and sizes |
| `model-first-shard.sha256` | `download-model.sh` | Q4 shard 1 integrity |
| `mtp-file.txt`, `mtp.sha256` | `download-mtp.sh` | MTP head size and integrity |
| `mmproj-file.txt`, `mmproj.sha256` | `download-vision.sh` | projector size and integrity |
| `mtp-runtime-version.txt`, `mtp-runtime-sha256.txt` | `build-mtp-runtime.sh` | built server version and binary hashes |
| `iq4-model-files.txt`, `iq4-first-shard.sha256` | `download-iq4.sh` | retained record of the deleted IQ4 download |

## Model selection

- Repository: `AtomicChat/Qwen3.8-Flash-Next-GGUF`
- Variant: `Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64`
- Dry-run result: 33 files, 94.5 GB total
- Shard 2: 38.4 GB isolated pageable n-gram table

The model's publisher recommends AD-4.27bpw over both AD-3.84bpw IQ4 and AD-5.00bpw Q5: its reported quality is effectively tied with Q5 while using 17.6 GB less storage, and its KLD is substantially lower than IQ4. Local throughput, context-allocation and bounded stability measurements are recorded in `RESULTS.md` and `summary.json`.
