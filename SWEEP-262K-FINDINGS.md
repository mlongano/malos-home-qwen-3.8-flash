# Native 262K sweep findings — 2026-09-21

## Deployed profile

- q8_0 target K/V, f16 draft K/V
- native 262,144 context
- CPU MoE 34
- batch 2,048; ubatch 512
- 16 threads strictly pinned to physical CPUs 0-15
- MTP depth 1 and vision enabled
- host prompt cache 24,576 MiB
- known-good pinned runtime `53b1389d0`

Active unit at the time: `qwen38-flash-native-mtp.service`, invocation
`750f3fcf53134254b24df29e9eeb94f8`. That transient unit was replaced on 2026-09-23 by the linked
`qwen-flash.service` (invocation `8613f853f7ad47efbd9762c01fbf9913`); `DEPLOYMENT.md` is the
current record of the service.

## Real 100K A/B

| Profile | Prefill | Decode | Peak VRAM | Free | Recall |
|---|---:|---:|---:|---:|---|
| Previous warmed profile | 80.15 t/s | 16.10 t/s | 29,722 MiB | 2,902 MiB | exact |
| Deployed profile | 95.73 t/s | 18.33 t/s | 30,833 MiB | 1,791 MiB | exact |
| CPU MoE 33 candidate | 96.68 t/s | 18.06 t/s | 31,798 MiB | 826 MiB | exact; rejected |

Deployed improvement: +19.4% prefill and +13.9% decode. Vision remained exact. MTP accepted
28/28 drafts on the measured 100K completion.

## Quality gate

Reference q8/q8 CPU-MoE-34 self-control was exact over 1,024 teacher-forced positions.

| Candidate | KLD | Top-1 | Result |
|---|---:|---:|---|
| q5/q5, CPU MoE 34 | 0.04087 | 94.43% | reject |
| q4/q4, CPU MoE 34 | 0.06795 | 91.31% | reject |
| q8/q4, CPU MoE 34 | 0.05993 | 90.92% | reject |
| q5/q4, CPU MoE 34 | 0.06319 | 92.19% | reject |
| q8/q8, CPU MoE 33 | 0.00546 | 98.24% | quality pass; VRAM reject |

Compressed target KV is not deployed.

## Prompt cache

A 100,000-token q8 state was prefetched in 1,041.8 seconds, displaced by a divergent request,
and restored in 1.20 seconds with all 100,000 tokens cached. Only four prompt tokens were
evaluated after restoration. Peak process RSS was 48,127 MiB.

## Rejected tuning

- Batch threads 32: severe regression.
- Draft q8 KV: used about 275 MiB more request-time VRAM than f16 in repeated probes.
- ubatch 1,024: insufficient VRAM.
- CPU MoE 33: faster in llama-bench, but real 100K margin was below 1 GiB.
- Compressed target KV: faster, but all formats failed the agreed quality thresholds.

## Compaction

`pi-extensions/remote-compaction.ts` is staged, documented as an available option, and deliberately
**not installed and not tested**. It uses Gemini 3.6 Flash with Qwen3.8 fallback, reasoning off and
a 4,096-token cap. Only static checks were run: `bun build` compiles it and `pi --extension` loads
it during `--list-models`. No compaction code path executed and no session content left the host.
The measured 39.4-minute compaction cost therefore stands, and Pi's default local compaction stays
in effect until the user reopens this.

## Evidence

- `results/vram-probe-20260921-1651/`
- `results/vram-probe-20260921-1703/`
- `results/vram-probe-20260921-1711/`
- `results/screen32k-20260921-1718/`
- `results/screen100k-20260921-1800/`
- `results/quality-kv-gate/`
- `results/real100k-v1/`
- `results/cache100k-v1/`
- `results/deploy-20260921-232158/`

Rollback checkpoint: `results/pre-sweep-checkpoint-20260921-165124/`.
