#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LABEL=${1:?label required}
PORT=${PORT:-18099}
OUT="$ROOT/results/real100k-v1/$LABEL"
mkdir -p "$OUT"
cleanup(){ kill "${pid:-0}" 2>/dev/null; wait "${pid:-0}" 2>/dev/null; }
trap cleanup EXIT

"$ROOT/run-mtp-pr-test.sh" > "$OUT/server.log" 2>&1 & pid=$!
for _ in $(seq 1 120); do
    curl -sf --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null && break
    kill -0 "$pid" 2>/dev/null || exit 1
    sleep 2
done

if (( ${WARM_TOKENS:-0} > 0 )); then
    "$ROOT/probe-workload.py" --port "$PORT" --image "$ROOT/results/vision-mtp-262k-v1/test.png" \
        --prompt-tokens "$WARM_TOKENS" --output "$OUT/warmup.json" > "$OUT/warmup.log" 2>&1
fi

read_before=$(awk '{print $3}' /sys/block/nvme1n1/stat)
fault_before=$(awk '/pgmajfault/{print $2}' /proc/vmstat)
swap_before=$(awk '/pswpin/{print $2}' /proc/vmstat)
"$ROOT/real-longcontext-test.py" --port "$PORT" \
    --source "$ROOT/results/real100k-v1/agent-source.txt" \
    --output "$OUT/result.json" --tokens 100000 > "$OUT/client.log" 2>&1 & work_pid=$!
peak=0; peak_rss=0
while kill -0 "$work_pid" 2>/dev/null; do
    used=$(rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/Used/{gsub(/ /,"",$NF);print int($NF/1048576)}')
    rss=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null)
    (( used > peak )) && peak=$used
    (( rss > peak_rss )) && peak_rss=$rss
    sleep 2
done
wait "$work_pid"; client_rc=$?
read_after=$(awk '{print $3}' /sys/block/nvme1n1/stat)
fault_after=$(awk '/pgmajfault/{print $2}' /proc/vmstat)
swap_after=$(awk '/pswpin/{print $2}' /proc/vmstat)
read_mib=$(awk -v d=$((read_after-read_before)) 'BEGIN{printf "%.1f",d/2048}')
printf 'pid=%s\nclient_rc=%s\npeak_vram_mib=%s\npeak_rss_mib=%s\nnvme_read_mib=%s\nmajor_faults=%s\nswapin_pages=%s\n' \
    "$pid" "$client_rc" "$peak" "$peak_rss" "$read_mib" \
    "$((fault_after-fault_before))" "$((swap_after-swap_before))" > "$OUT/metrics.txt"
exit "$client_rc"
