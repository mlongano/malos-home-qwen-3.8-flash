#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.env
source "$ROOT/config.env"
DEST="$ROOT/models"
PROV="$ROOT/provenance"
FIRST="$DEST/$MODEL_VARIANT/$MODEL_FIRST_SHARD"

if [[ ! -x "$HF_BIN" ]]; then
    echo "download-model: Hugging Face client is missing: $HF_BIN" >&2
    exit 1
fi

if [[ ! -e "$FIRST" ]]; then
    avail=$(df --output=avail -B1 "$ROOT" | tail -1 | tr -d ' ')
    minimum=$((110 * 1024 * 1024 * 1024))
    if (( avail < minimum )); then
        echo "download-model: need at least 110 GiB free before a fresh download; have $((avail / 1024 / 1024 / 1024)) GiB" >&2
        exit 1
    fi
fi

mkdir -p "$DEST" "$PROV"
"$HF_BIN" download "$HF_REPO" \
    --include "$MODEL_VARIANT/*" \
    --local-dir "$DEST"

count=$(find "$DEST/$MODEL_VARIANT" -maxdepth 1 -type f -name '*.gguf' | wc -l)
if [[ "$count" -ne 33 || ! -r "$FIRST" ]]; then
    echo "download-model: expected 33 readable GGUF shards, found $count" >&2
    exit 1
fi

find "$DEST/$MODEL_VARIANT" -maxdepth 1 -type f -name '*.gguf' -print0 \
    | sort -z | xargs -0 stat -c '%n %s' > "$PROV/model-files.txt"
sha256sum "$FIRST" > "$PROV/model-first-shard.sha256"
echo "download-model: complete: $MODEL_VARIANT ($count shards)"
