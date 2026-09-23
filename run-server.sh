#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.env
source "$ROOT/config.env"

MODEL_PROFILE=${MODEL_PROFILE:-q4}
case "$MODEL_PROFILE" in
    q4) ;;
    iq4)
        MODEL_VARIANT=$IQ4_VARIANT
        MODEL_FIRST_SHARD=$IQ4_FIRST_SHARD
        ;;
    *)
        echo "run-server: MODEL_PROFILE must be q4 or iq4" >&2
        exit 2
        ;;
esac
MODEL="$ROOT/models/$MODEL_VARIANT/$MODEL_FIRST_SHARD"
PORT=${PORT:-$DEFAULT_PORT}
CTX_SIZE=${CTX_SIZE:-$DEFAULT_CTX}
N_CPU_MOE=${N_CPU_MOE:-$DEFAULT_N_CPU_MOE}
THREADS=${THREADS:-$DEFAULT_THREADS}
LAZY_MODE=${LAZY_MODE:-on}
MTP=${MTP:-0}
MTP_MODEL="$ROOT/models/unsloth-Qwen3.8-Flash-Next-GGUF/$MTP_FILE"

if [[ ! -r "$MODEL" ]]; then
    echo "run-server: model is missing; run ./download-model.sh first" >&2
    exit 1
fi
if [[ ! -x "$LLAMA_BIN/llama-server" ]]; then
    echo "run-server: llama-server is missing: $LLAMA_BIN/llama-server" >&2
    exit 1
fi

export LD_LIBRARY_PATH="$LLAMA_BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HSA_ENABLE_SDMA=${HSA_ENABLE_SDMA:-1}

if [[ "$MTP" != 0 && ! -r "$MTP_MODEL" ]]; then
    echo "run-server: MTP requested but the draft is missing; run ./download-mtp.sh" >&2
    exit 1
fi

printf 'run-server: profile=%s model=%s ctx=%s n_cpu_moe=%s lazy=%s mtp=%s port=%s\n' \
    "$MODEL_PROFILE" "$MODEL_VARIANT" "$CTX_SIZE" "$N_CPU_MOE" "$LAZY_MODE" "$MTP" "$PORT" >&2

args=(
    --model "$MODEL"
    --alias qwen3.8-flash-next
    --host 127.0.0.1 --port "$PORT"
    --ctx-size "$CTX_SIZE" --parallel 1
    --n-gpu-layers 99 --n-cpu-moe "$N_CPU_MOE"
    --no-op-offload --fit off
    --load-mode mmap --lazy-mode "$LAZY_MODE"
    --flash-attn on --jinja
    --cache-type-k q8_0 --cache-type-v q8_0
    --threads "$THREADS" --threads-batch "$THREADS"
    --batch-size 2048 --ubatch-size 256
    --no-cache-prompt --no-webui
)
if (( CTX_SIZE > 262144 )); then
    case "$CTX_SIZE" in
        524288) rope_scale=2 ;;
        1048576) rope_scale=4 ;;
        *)
            echo "run-server: extended context must be 524288 or 1048576" >&2
            exit 2
            ;;
    esac
    args+=(--rope-scaling yarn --rope-scale "$rope_scale" --yarn-orig-ctx 262144 --ctx-checkpoints 0)
fi
if [[ "$MTP" != 0 ]]; then
    args+=(--model-draft "$MTP_MODEL" --spec-type draft-mtp --spec-draft-n-max 2)
fi

exec "$LLAMA_BIN/llama-server" "${args[@]}"
