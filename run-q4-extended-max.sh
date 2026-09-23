#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export MODEL_PROFILE=q4
export CTX_SIZE=1048576
export N_CPU_MOE=48
export LAZY_MODE=on
export MTP=0
exec "$ROOT/run-server.sh"
