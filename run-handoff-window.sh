#!/usr/bin/env bash
# QWEN_FLASH_HANDOFF.md window: transient unit -> installed unit, verified, with rollback.
# Self-contained on purpose. It runs as the last action of a turn whose model is served by the
# server it restarts, so every decision it needs is already encoded here.
set -uo pipefail

ROOT=/media/NVME_DATA/MOUNTS/Models/qwen-3.8-flash
cd "$ROOT"
UNIT=qwen-flash
OLD=qwen38-flash-native-mtp
REP="$ROOT/results/handoff-window-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$REP"
status_log="$REP/report.txt"
: > "$status_log"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$status_log"; }

rollback() {
    local reason=$1
    log "ROLLBACK ($reason)"
    systemctl --user stop "$UNIT.service" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$UNIT.service"
    systemctl --user daemon-reload 2>/dev/null || true
    systemd-run --user --unit="$OLD" --description="Qwen3.8 Flash Next Q4 native 262K MTP server" \
        --working-directory="$ROOT" "$ROOT/run-q4-native-mtp.sh" >> "$REP/rollback.log" 2>&1 || true
    for _ in $(seq 1 180); do
        curl -sf --max-time 3 http://127.0.0.1:18080/health > /dev/null 2>&1 && {
            log "rollback complete: transient unit serving again"
            return 0
        }
        sleep 2
    done
    log "ROLLBACK DID NOT RESTORE SERVICE - check $REP/rollback.log"
    return 1
}

# ---- preconditions (abort before any change) ---------------------------------------------------
lease=$(pi-inference status 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('lease'))" 2>/dev/null || echo unknown)
log "manager lease: $lease"
[[ $lease == None ]] || { log "aborting: a lease is active, someone is using the GPU"; exit 2; }

before_args=$(tr '\0' '\n' < "/proc/$(systemctl --user show $OLD.service -p MainPID --value)/cmdline" 2>/dev/null) || {
    log "aborting: $OLD.service is not running"; exit 2; }
printf '%s\n' "$before_args" > "$REP/cmdline-before.txt"
sha256sum run-q4-native-mtp.sh run-mtp-pr-test.sh runtime/build-mtp/bin/llama-server > "$REP/sha256-before.txt"
for u in pi-llama-router unsloth ds4-server; do
    [[ $(systemctl --user is-active $u.service 2>/dev/null) == active ]] && { log "aborting: $u is active"; exit 2; }
done
log "preconditions ok; swapping to installed unit"

# ---- the swap ----------------------------------------------------------------------------------
systemctl --user stop "$OLD.service" || { rollback "could not stop $OLD"; exit 3; }
ln -sfn "$ROOT/systemd/$UNIT.service" "$HOME/.config/systemd/user/$UNIT.service" || { rollback "symlink"; exit 3; }
systemctl --user daemon-reload || { rollback "daemon-reload"; exit 3; }
systemctl --user start "$UNIT.service" || { rollback "start $UNIT"; exit 3; }

for i in $(seq 1 240); do
    curl -sf --max-time 3 http://127.0.0.1:18080/health > /dev/null 2>&1 && break
    systemctl --user is-active --quiet "$UNIT.service" || { rollback "service died during load"; exit 3; }
    sleep 2
done
curl -sf --max-time 5 http://127.0.0.1:18080/health > "$REP/health.json" 2>/dev/null || {
    rollback "never became healthy"; exit 3; }
log "healthy on the installed unit"

# ---- verification ------------------------------------------------------------------------------
pid=$(systemctl --user show "$UNIT.service" -p MainPID --value)
inv=$(systemctl --user show "$UNIT.service" -p InvocationID --value)
systemctl --user show "$UNIT.service" -p UnitFileState -p LoadState -p ActiveState -p MainPID -p InvocationID \
    > "$REP/service.txt" 2>&1
tr '\0' '\n' < "/proc/$pid/cmdline" > "$REP/cmdline-after.txt"
missing=""
for flag in '--ctx-size 262144' '--n-cpu-moe 34' '--cache-type-k q8_0' '--cache-type-v q8_0' \
            '--ubatch-size 512' '--batch-size 2048' '--cache-ram 24576' '--cpu-range 0-15' \
            '--cpu-strict 1' '--spec-draft-n-max 1'; do
    grep -qF -- "$flag" "$REP/cmdline-after.txt" || missing="$missing [$flag]"
done
[[ -z $missing ]] && log "arguments preserved" || log "ARGUMENT DRIFT:$missing"

peak=0
./probe-workload.py --port 18080 --image results/vision-mtp-262k-v1/test.png --prompt-tokens 4096 \
    --output "$REP/workload.json" > "$REP/workload.log" 2>&1 &
wp=$!
while kill -0 "$wp" 2>/dev/null; do
    used=$(rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/Used/{gsub(/ /,"",$NF);print int($NF/1048576)}')
    (( used > peak )) && peak=$used
    sleep 2
done
wait "$wp"
python3 - "$REP" <<'PY'
import json, sys, pathlib
rep = pathlib.Path(sys.argv[1])
d = json.load(open(rep / "workload.json"))
vision_ok = d["vision_content"].strip() == "VISION 731\nYELLOW CARD"
text = d.get("text_timings") or {}
out = {
    "vision_exact": vision_ok,
    "prefill_tps_4k": round(text.get("prompt_per_second") or 0, 2),
    "vision_decode_tps": round((d.get("vision_timings") or {}).get("predicted_per_second") or 0, 2),
}
print(("vision exact" if vision_ok else "VISION MISMATCH"), out["prefill_tps_4k"], "t/s prefill")
json.dump(out, open(rep / "verify.json", "w"), indent=2)
PY
log "peak vram during workload: ${peak} MiB (card 32624)"

# ---- provider: additive, so no session is orphaned ---------------------------------------------
cp -a "$HOME/.pi/agent/models.json" "$HOME/.pi/agent/models.json.bak-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY' | tee -a "$status_log"
import json, os
p = os.path.expanduser("~/.pi/agent/models.json")
d = json.load(open(p))
providers = d["providers"]
if "qwen-flash" in providers:
    print("provider qwen-flash already present; leaving alone")
else:
    providers["qwen-flash"] = json.loads(json.dumps(providers["malos-home"]))
    providers["qwen-flash"]["name"] = "Qwen3.8 Flash Next (qwen-flash)"
    tmp = p + ".tmp"
    json.dump(d, open(tmp, "w"), indent=2)
    os.replace(tmp, p)
    print("added qwen-flash alongside malos-home; providers:", list(providers))
PY

cat > "$REP/summary.json" <<EOF
{"unit":"$UNIT","invocation":"$inv","pid":$pid,"peak_vram_mib":$peak,
 "arg_drift":"${missing:-none}","provider":"qwen-flash added alongside malos-home",
 "docs_updated":false,"report":"$REP"}
EOF
ln -sfn "$REP" "$ROOT/results/latest-handoff-window"
log "WINDOW COMPLETE — report in $REP"
log "NEXT (docs): DEPLOYMENT.md, README.md, summary.json; ECOSYSTEM.md + PI_INFERENCE_CONTROL_PLANE.md"
log "NEXT (Phase 1): qwen-flash mode in the manager; then remove the malos-home provider entry"
