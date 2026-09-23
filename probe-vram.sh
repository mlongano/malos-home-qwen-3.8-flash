#!/usr/bin/env bash
# Production-shape feasibility probe: native 262K, MTP, vision, text prefill and image decode.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT="$ROOT/results/vram-probe-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
if systemctl --user is-active --quiet qwen38-flash-native-mtp.service; then
    echo "probe-vram: production service is still active; stop it after switching Pi models" >&2
    exit 1
fi

PORT="${PROBE_PORT:-18099}"
MARGIN_MIB="${MARGIN_MIB:-1024}"
IMAGE="$ROOT/results/vision-mtp-262k-v1/test.png"

vram_used() {
    rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/Used/{gsub(/ /,"",$NF); print int($NF/1048576)}'
}
vram_total() {
    rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/Total Memory/{gsub(/ /,"",$NF); print int($NF/1048576)}'
}

TOTAL=$(vram_total)
echo "gpu total ${TOTAL} MiB; accepting request-time peaks up to $((TOTAL - MARGIN_MIB)) MiB"
echo "config,ctk,ctv,draft_kv,ubatch,ncmoe,peak_mib,free_mib,workload_ok,verdict" > "$OUT/feasibility.csv"

# Keep K at higher precision in mixed candidates because attention scores are usually more
# sensitive to K; V compression buys most of the same memory without forcing an all-q4 choice.
default_specs=(
    "current|q8_0|q8_0|f16|256|34"
    "q8_ub512_n34|q8_0|q8_0|f16|512|34"
    "q8_draftq8_ub512_n34|q8_0|q8_0|q8_0|512|34"
)
if (( $# )); then specs=("$@"); else specs=("${default_specs[@]}"); fi
for spec in "${specs[@]}"; do
    IFS='|' read -r name ctk ctv ctd ub ncmoe <<< "$spec"
    echo "--- $name (K=$ctk V=$ctv draft=$ctd ubatch=$ub ncmoe=$ncmoe)"
    CT_K="$ctk" CT_V="$ctv" CT_K_DRAFT="$ctd" CT_V_DRAFT="$ctd" \
    UBATCH_SIZE="$ub" BATCH_SIZE=2048 N_CPU_MOE="$ncmoe" \
    CTX_SIZE=262144 PORT="$PORT" BIND_HOST=127.0.0.1 MTP=1 VISION=1 CACHE_RAM_MIB=24576 \
        nohup "$ROOT/run-mtp-pr-test.sh" > "$OUT/$name.server.log" 2>&1 &
    pid=$!
    healthy=0
    for _ in $(seq 1 90); do
        curl -sf --max-time 3 "http://127.0.0.1:$PORT/health" > /dev/null && { healthy=1; break; }
        kill -0 "$pid" 2> /dev/null || break
        sleep 2
    done

    peak=$(vram_used)
    workload_ok=0
    if [[ $healthy == 1 ]]; then
        timeout 600 "$ROOT/probe-workload.py" --port "$PORT" --image "$IMAGE" \
            --output "$OUT/$name.workload.json" &
        work_pid=$!
        while kill -0 "$work_pid" 2> /dev/null; do
            used=$(vram_used); (( used > peak )) && peak=$used
            sleep 1
        done
        if wait "$work_pid"; then
            used=$(vram_used); (( used > peak )) && peak=$used
            if python3 - "$OUT/$name.workload.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("vision_content") == "VISION 731\nYELLOW CARD" else 1)
PY
            then workload_ok=1; fi
        fi
    fi

    free=$((TOTAL - peak))
    if [[ $healthy == 1 && $workload_ok == 1 && $free -ge $MARGIN_MIB ]]; then
        verdict=fit
    else
        verdict=rejected
    fi
    echo "$name,$ctk,$ctv,$ctd,$ub,$ncmoe,$peak,$free,$workload_ok,$verdict" >> "$OUT/feasibility.csv"
    printf '    %s peak %s MiB, free %s MiB, workload %s -> %s\n' \
        "$name" "$peak" "$free" "$workload_ok" "$verdict"
    kill "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
    sleep 5
done

echo "wrote $OUT/feasibility.csv"
