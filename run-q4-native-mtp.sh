#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export BIND_HOST=0.0.0.0
export PORT=18080
export CTX_SIZE=262144
export N_CPU_MOE=34
export CT_K=q8_0
export CT_V=q8_0
export CT_K_DRAFT=f16
export CT_V_DRAFT=f16
export BATCH_SIZE=2048
export UBATCH_SIZE=512
export THREADS=16
export THREADS_BATCH=16
export CPU_RANGE=0-15
export CPU_RANGE_BATCH=0-15
export CPU_STRICT=1
export CPU_STRICT_BATCH=1
export CACHE_RAM_MIB=24576
export VISION=1
export IMAGE_MIN_TOKENS=1024
export MTP=1
export MTP_DRAFT_MAX=1
export MTP_BACKEND_SAMPLING=1
export MODEL_ALIAS=qwen3.8-flash-next
exec "$ROOT/run-mtp-pr-test.sh"
