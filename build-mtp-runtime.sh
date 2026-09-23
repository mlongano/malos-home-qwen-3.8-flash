#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE="$ROOT/runtime/llama.cpp-mtp"
BUILD="$ROOT/runtime/build-mtp"
PROV="$ROOT/provenance"
PIN=53b1389d0bf98fa367e2a0ce0475008e762ebf28

if [[ ! -d "$SOURCE/.git" ]]; then
    echo "build-mtp-runtime: source clone is missing: $SOURCE" >&2
    exit 1
fi
actual=$(git -C "$SOURCE" rev-parse HEAD)
if [[ "$actual" != "$PIN" ]]; then
    echo "build-mtp-runtime: expected $PIN, found $actual" >&2
    exit 1
fi
if [[ -n $(git -C "$SOURCE" status --porcelain) ]]; then
    echo "build-mtp-runtime: source checkout is dirty" >&2
    exit 1
fi

HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_HIP=ON \
    -DGPU_TARGETS=gfx1201 \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF
cmake --build "$BUILD" --target llama-server -- -j16

BIN="$BUILD/bin"
mkdir -p "$PROV"
"$BIN/llama-server" --version 2>&1 | tee "$PROV/mtp-runtime-version.txt"
sha256sum "$BIN/llama-server" "$BIN/libllama.so" "$BIN/libggml-hip.so" \
    > "$PROV/mtp-runtime-sha256.txt"
