# Active native-context MTP service

Deployed 2026-09-20, optimized 2026-09-21, and moved off the transient unit on 2026-09-23 via the
handoff window (`local-models/QWEN_FLASH_HANDOFF.md`):

- Unit: `qwen-flash.service` — a linked unit file, `systemd/qwen-flash.service` in this project
- Invocation: `8613f853f7ad47efbd9762c01fbf9913`
- Bind: `0.0.0.0:18080`
- Local endpoint: `http://127.0.0.1:18080/v1`
- Tailnet endpoint: `http://malos-home.taile1900.ts.net:18080/v1`
- Alias: `qwen3.8-flash-next`
- Launcher: `run-q4-native-mtp.sh`
- Quant: `AD-4.27bpw-Q4_K_M-M64`
- Context allocation: 262,144 native tokens
- CPU MoE layers: 34
- KV: Q8_0 K and V
- Lazy n-gram mmap: enabled
- Vision projector: `mmproj-Qwen3.8-Flash-Next-F16.gguf`
- Minimum image tokens: 1,024
- MTP head: shared Q8_0
- MTP draft depth: 1
- HSA SDMA: enabled
- Prompt cache: **enabled**, 24,576 MiB host budget
- Micro-batch: 512
- CPU placement: 16 threads strictly pinned to physical CPUs 0-15

Runtime:

- llama.cpp PR #28243 commit `53b1389d0bf98fa367e2a0ce0475008e762ebf28`
- Build 11048, compiled locally for `gfx1201`
- Project-local fixed ROCr from the DeepSeek project (`../ds4/misc/rocm-local-runtime-fixed-prefix/lib`),
  built from a patch that exists nowhere else — `UPSTREAM.md` §"The ROCr prefix is a single point
  of failure"
- System `libamdhip64.so.7.2.53211`

Upstream intake — moving the llama.cpp pin or judging a newer PR #28243 head:
`UPSTREAM.md` (procedure with completion criteria, benefit bar, hard constraints, rollback).

The production vision request transcribed `VISION 731` and `YELLOW CARD` exactly, completed normally at 19.03 t/s, and accepted 22/23 MTP drafts. It used 29,447 MiB VRAM and 37,728 MiB RSS. The same image passed through Pi's documented `@image` CLI path. Evidence is retained under `results/native-mtp-service/` and `results/vision-mtp-262k-v1/`.

Behaviour note: thinking is enabled by default, so replies carry `reasoning_content` and consume
output budget before any visible text. A client that asks for only a few tokens gets empty
`content`. Pass `chat_template_kwargs: {"enable_thinking": false}` to disable it, which turned a
32-token trivial reply into 2 tokens.

This is a real linked unit (`systemd/qwen-flash.service` symlinked into
`~/.config/systemd/user/`), so it survives daemon-reload and inspection, restarts itself on
failure, and can be stopped cleanly.

The inference manager owns it since 2026-09-23: `qwen-flash` is a mode, `pi-inference stop` stops
this unit, a transition away from it refuses while a request is in flight, and a transition into it
refuses while another owner holds the card (`--force` overrides, as with the other modes). The unit
file itself stays **not `enable`d**: auto-start on login would compete with the manager for the one
card, and transitions are the manager's job, not the unit's.

```sh
pi-inference qwen-flash                       # the normal way in; the manager starts the unit
systemctl --user status qwen-flash.service
systemctl --user stop qwen-flash.service      # by hand, e.g. with the manager down
journalctl --user -u qwen-flash.service -f
```

A restart discards the 24 GiB prompt cache, and a 250K-token conversation then costs a full
re-prefill of about 45 minutes at the measured rates; `UPSTREAM.md` treats that as a scheduling
constraint rather than a surprise to spring on the service.

The predecessor transient unit `qwen38-flash-native-mtp.service` no longer exists. If the installed
unit ever has to be abandoned, that is still the fallback:

```sh
systemd-run --user --unit=qwen38-flash-native-mtp --description='Qwen3.8 Flash Next Q4 native 262K MTP server' --working-directory="$PWD" "$PWD/run-q4-native-mtp.sh"
```

### Post-swap verification (2026-09-23)

Report: `results/latest-handoff-window/` (`report.txt`, `service.txt`, `workload.json`).

| Check | Result |
|---|---|
| health | `{"status":"ok"}` |
| unit state | `LoadState=loaded`, `ActiveState=active`, `UnitFileState=linked` |
| launch arguments | all 12 spot-checked flags identical to the pre-swap process |
| vision card | exact: `VISION 731` / `YELLOW CARD` |
| 4,096-token prefill | 116.65 t/s |
| vision decode | 19.62 t/s |
| peak VRAM during that workload | 30,552 MiB of 32,624 |

Two findings about the window script itself, both mine and both worth keeping in the record: the
argument check compared `tr '\0' '\n'` output against two-word patterns, so flag and value landed on
separate lines and every flag reported as drift — a false alarm, correct only after re-comparing on
a joined command line. And the in-window vision probe timed out because it fired seconds after
`/health` went green, while experts were still faulting in; the script carried on and declared the
window complete with its verification step silently failed. Re-run synchronously it passes. Do not
read a completed log as a passed check.

## Network access

The server listens directly on every IPv4 interface. Verified endpoints include:

- Loopback: `http://127.0.0.1:18080/v1`
- Tailnet IPv4: `http://100.104.52.87:18080/v1`
- Tailnet MagicDNS: `http://malos-home.taile1900.ts.net:18080/v1`
- Tailnet short name: `http://malos-home:18080/v1`
- LAN: `http://192.168.1.2:18080/v1` and `http://192.168.1.157:18080/v1`

Health checks passed through loopback, Tailscale, MagicDNS and both LAN addresses. The former `qwen38-tailscale-proxy.service` is inactive and no longer needed. The API has no key configured and permits all CORS origins, so any network peer allowed through the host/network firewall can submit requests.

### Long-context tuning (active)

The active service uses ubatch 512, strict CPUs 0-15 and `--cache-ram 24576`. A warmed real
100,109-token request improved from 80.15 t/s on the previous profile to 95.73 t/s, with exact
key recall, exact vision and 1,791 MiB free at the measured VRAM peak.

A 100,000-token q8 prompt state was saved after divergence and restored all 100,000 tokens in
1.20 seconds. The first prefill took 1,041.8 seconds. The 24 GiB limit is host RAM, not VRAM, and
is sized for the estimated 20.3 GiB full native context state.

## One slot, one client

`--parallel 1`: one slot, so one conversation at a time. A second client does not queue politely
behind the first — it arrives as a different prompt, and llama.cpp evicts the resident slot state to
serve it, which is a full re-prefill for whoever was there (`RESULTS.md`, "Why prefix caching
silently stops working"). Pi and the panel's chat cannot usefully share this endpoint while a long
conversation is live.

## Compaction on this endpoint

Pi auto-compacts at `contextWindow − reserveTokens`, which for this model is 262,144 − 16,384 =
**245,760 tokens** (the 16,384 default; `~/.pi/agent/settings.json` changes it). One compaction
measured from the live log: 136,627 prompt tokens at 77.9 t/s, then 7,553 summary tokens at
12.4 t/s — **39.4 minutes**, three quarters of it re-prefill (`EVIDENCE.md`). It cannot be made
cheap: Pi gives compaction a fresh routing session and disables cache writes, and llama.cpp disables
`--cache-reuse` whenever a multimodal projector is loaded, so neither the live KV nor chunk reuse
can be borrowed (`PLAN-262K-SWEEP.md`).

Near the ceiling, one compaction is a 40-minute turn. `pi-extensions/remote-compaction.ts` exists
for that reason and is deliberately not installed.

## Coexistence

- **Studio's STT sidecar**: on 2026-09-26 its `llama-server` (Studio's own llama.cpp build) crashed
  while this service held ~29.5 GiB of the 32 GiB card. The sidecar's "GPU when available" mode does
  not know a committed owner when it picks a device. Forced to CPU, transcription worked alongside
  this service; treat the sidecar as CPU-only while `qwen-flash` is resident.
- **ComfyUI, the panel and ds4**: all card owners. The manager's mode switch is the only supported
  way to move between them, and ds4 additionally wants `/mnt/ram`, which stays unmounted here.
- **A second 262K server**: `run-real100k.sh` starts its own server on port 18099 and must not run
  while `qwen-flash.service` is up. Two 262K servers do not fit on one card.

## Control plane

This project owns the model and its measurements; the manager owns when it runs. The design, the
mode vocabulary, the lease and occupancy rules and the phases still open are in the `local-models`
project: `QWEN_FLASH_CONTROL_PLANE.md`, with `QWEN_FLASH_HANDOFF.md` for the executed handoff
window. Phase 3 — a vhost, a model API key and narrower CORS — is what would replace the open
`0.0.0.0:18080` bind described under "Network access".

The service does not start by itself: it is not `enable`d, and the manager starts it when the
`qwen-flash` mode is selected. DeepSeek is stopped and `/mnt/ram` is unmounted while this service is
active (checked 2026-09-29) — the two cannot share the card, and ds4 is the one that wants the RAM
disk.
