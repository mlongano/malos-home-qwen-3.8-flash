# Active native-context MTP service

Deployed 2026-09-20 and optimized 2026-09-21 as a transient user service:

- Unit: `qwen38-flash-native-mtp.service`
- Invocation: `750f3fcf53134254b24df29e9eeb94f8`
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
- Project-local fixed ROCr from the DeepSeek project
- System `libamdhip64.so.7.2.53211`

The production vision request transcribed `VISION 731` and `YELLOW CARD` exactly, completed normally at 19.03 t/s, and accepted 22/23 MTP drafts. It used 29,447 MiB VRAM and 37,728 MiB RSS. The same image passed through Pi's documented `@image` CLI path. Evidence is retained under `results/native-mtp-service/` and `results/vision-mtp-262k-v1/`.

Behaviour note: thinking is enabled by default, so replies carry `reasoning_content` and consume
output budget before any visible text. A client that asks for only a few tokens gets empty
`content`. Pass `chat_template_kwargs: {"enable_thinking": false}` to disable it, which turned a
32-token trivial reply into 2 tokens.

This is a transient `systemd-run --user` unit and does not auto-start after reboot. Manage it with:

```sh
systemctl --user status qwen38-flash-native-mtp.service
systemctl --user stop qwen38-flash-native-mtp.service
```

Recreate it from the project directory with:

```sh
systemd-run --user --unit=qwen38-flash-native-mtp --description='Qwen3.8 Flash Next Q4 native 262K MTP server' --working-directory="$PWD" "$PWD/run-q4-native-mtp.sh"
```

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

The model service is transient and must be recreated after reboot. DeepSeek remains stopped and `/mnt/ram` remains unmounted while this service is active.
