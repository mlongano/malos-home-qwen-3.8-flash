#!/usr/bin/env bash
# Long-context relative speed sweep with llama-bench from the pinned PR source.
# Spec format: name|ctk|ctv|ubatch|n_cpu_moe
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN="${BIN_DIR:-$ROOT/runtime/build-mtp/bin}"
BASE="$ROOT/models/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-00001-of-00033.gguf"

# Same patched ROCr as the production launcher, resolved the same way: an unreadable ds4 prefix must
# not silently turn a sweep into a measurement of the system ROCr. UPSTREAM.md, "The ROCr prefix is
# a single point of failure".
DS4_ROCR="$ROOT/../ds4/misc/rocm-local-runtime-fixed-prefix/lib"
OPT_ROCR="$HOME/.local/opt/rocr-r9700/lib"
FIXED_ROCR="${FIXED_ROCR:-}"
if [[ -z "$FIXED_ROCR" || ! -r "$FIXED_ROCR/libhsa-runtime64.so.1" ]]; then
    FIXED_ROCR=""
    for candidate in "$DS4_ROCR" "$OPT_ROCR"; do
        if [[ -r "$candidate/libhsa-runtime64.so.1" ]]; then
            FIXED_ROCR="$candidate"
            break
        fi
    done
fi
if [[ -z "$FIXED_ROCR" ]]; then
    echo "sweep-longcontext: the patched ROCr runtime is missing" >&2
    echo "  looked in: $DS4_ROCR $OPT_ROCR" >&2
    echo "  a sweep against the system ROCr would not describe production" >&2
    exit 1
fi
export LD_LIBRARY_PATH="$BIN:$FIXED_ROCR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HSA_ENABLE_SDMA=1

PP="${PP_TOKENS:-100000}"
TG="${TG_TOKENS:-64}"
OUTTAG="${OUTTAG:-longcontext}"
OUT="$ROOT/results/$OUTTAG-$(date +%Y%m%d-%H%M)"
mkdir -p "$OUT"
if systemctl --user is-active --quiet qwen38-flash-native-mtp.service; then
    echo "sweep-longcontext: production service is still active" >&2
    exit 1
fi

vram_used() {
    rocm-smi --showmeminfo vram 2>/dev/null | awk -F: '/Used/{gsub(/ /,"",$NF); print int($NF/1048576)}'
}

run() {
    local name=$1 ctk=$2 ctv=$3 ub=$4 ncmoe=$5
    echo "=== $name (K=$ctk V=$ctv ubatch=$ub ncmoe=$ncmoe) pp=$PP tg=$TG"
    ( "$BIN/llama-bench" -m "$BASE" -pg "$PP,$TG" \
        -ctk "$ctk" -ctv "$ctv" -ub "$ub" -b 2048 -ncmoe "$ncmoe" \
        -ngl 99 -fa on -lm mmap -lzm on -nopo 1 -t 16 -r 1 -o json \
        > "$OUT/$name.json" 2> "$OUT/$name.log" ) &
    local pid=$! peak=0
    while kill -0 "$pid" 2> /dev/null; do
        local used; used=$(vram_used); (( used > peak )) && peak=$used
        sleep 2
    done
    wait "$pid"; local rc=$?
    echo "    peak ${peak} MiB, exit $rc"
    echo "$name $ctk $ctv $ub $ncmoe $peak $rc" > "$OUT/$name.peak"
}

for spec in "${@:-}"
do
    [[ -z $spec ]] && continue
    IFS='|' read -r name ctk ctv ub ncmoe <<< "$spec"
    run "$name" "$ctk" "$ctv" "$ub" "$ncmoe"
done

echo "wrote $OUT"
