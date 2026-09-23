#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN="${BIN_DIR:-$ROOT/runtime/build-mtp/bin}"
SERVER="$BIN/llama-server"
BASE="$ROOT/models/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-00001-of-00033.gguf"
DRAFT="$ROOT/models/unsloth-Qwen3.8-Flash-Next-GGUF/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
MMPROJ="$ROOT/models/mmproj-Qwen3.8-Flash-Next-F16.gguf"
FIXED_ROCR="$ROOT/../ds4/misc/rocm-local-runtime-fixed-prefix/lib"

for file in "$SERVER" "$BASE" "$DRAFT" "$FIXED_ROCR/libhsa-runtime64.so.1"; do
    if [[ ! -r "$file" ]]; then
        echo "run-mtp-pr-test: required file is missing: $file" >&2
        exit 1
    fi
done

export LD_LIBRARY_PATH="$BIN:$FIXED_ROCR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HSA_ENABLE_SDMA=1

vision_args=()
if [[ ${VISION:-0} == 1 ]]; then
    if [[ ! -r "$MMPROJ" ]]; then
        echo "run-mtp-pr-test: vision projector is missing: $MMPROJ" >&2
        exit 1
    fi
    vision_args=(
        --mmproj "$MMPROJ"
        --image-min-tokens "${IMAGE_MIN_TOKENS:-1024}"
    )
fi

spec_args=()
if [[ ${MTP:-1} == 1 ]]; then
    spec_args=(
        --model-draft "$DRAFT"
        --spec-type draft-mtp
        --spec-draft-n-max "${MTP_DRAFT_MAX:-2}"
        --spec-draft-type-k "${CT_K_DRAFT:-f16}"
        --spec-draft-type-v "${CT_V_DRAFT:-f16}"
    )
    if [[ ${MTP_BACKEND_SAMPLING:-1} == 0 ]]; then
        spec_args+=(--no-spec-draft-backend-sampling)
    fi
fi

# The prompt cache holds KV state copies in host RAM, capped by --cache-ram (upstream default
# 8192 MiB). At 81 KiB of KV per token that ceiling is ~104k tokens, so a larger prompt is
# silently not cached and any slot reset recomputes it at ~78 t/s. 262,144 tokens needs ~20.3 GiB;
# 24576 covers the full context. This is host memory, not VRAM, and the limit shrinks itself on
# allocation failure.
cache_args=(
    --cache-prompt
    --cache-ram "${CACHE_RAM_MIB:-24576}"
    --ctx-checkpoints "${CTX_CHECKPOINTS:-32}"
    --checkpoint-min-step "${CHECKPOINT_MIN_STEP:-8192}"
)
if [[ ${CACHE_PROMPT:-1} == 0 ]]; then
    cache_args=(--no-cache-prompt)
elif [[ ${CACHE_IDLE_SLOTS:-1} == 0 ]]; then
    cache_args+=(--no-cache-idle-slots)
fi

cpu_args=(
    --threads "${THREADS:-16}"
    --threads-batch "${THREADS_BATCH:-16}"
)
if [[ -n ${CPU_RANGE:-} ]]; then
    cpu_args+=(--cpu-range "$CPU_RANGE")
fi
if [[ -n ${CPU_RANGE_BATCH:-} ]]; then
    cpu_args+=(--cpu-range-batch "$CPU_RANGE_BATCH")
fi
if [[ ${CPU_STRICT:-0} == 1 ]]; then
    cpu_args+=(--cpu-strict 1)
fi
if [[ ${CPU_STRICT_BATCH:-0} == 1 ]]; then
    cpu_args+=(--cpu-strict-batch 1)
fi

exec "$SERVER" \
    --model "$BASE" \
    "${vision_args[@]}" \
    "${spec_args[@]}" \
    --alias "${MODEL_ALIAS:-qwen3.8-flash-next-mtp-test}" \
    --host "${BIND_HOST:-127.0.0.1}" \
    --port "${PORT:-18081}" \
    --ctx-size "${CTX_SIZE:-32768}" \
    --parallel 1 \
    --n-gpu-layers 99 \
    --n-cpu-moe "${N_CPU_MOE:-28}" \
    --no-op-offload \
    --fit off \
    --load-mode mmap \
    --lazy-mode on \
    --flash-attn on \
    --jinja \
    --cache-type-k "${CT_K:-q8_0}" \
    --cache-type-v "${CT_V:-q8_0}" \
    "${cpu_args[@]}" \
    --batch-size "${BATCH_SIZE:-2048}" \
    --ubatch-size "${UBATCH_SIZE:-256}" \
    "${cache_args[@]}" \
    --no-webui
