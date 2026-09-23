#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.env
source "$ROOT/config.env"
DEST="$ROOT/models"
PROV="$ROOT/provenance"
FIRST="$DEST/$IQ4_VARIANT/$IQ4_FIRST_SHARD"

if [[ ! -x "$HF_BIN" ]]; then
    echo "download-iq4: Hugging Face client is missing: $HF_BIN" >&2
    exit 1
fi
if [[ ! -e "$FIRST" ]]; then
    avail=$(df --output=avail -B1 "$ROOT" | tail -1 | tr -d ' ')
    minimum=$((105 * 1024 * 1024 * 1024))
    if (( avail < minimum )); then
        echo "download-iq4: need at least 105 GiB free before a fresh download; have $((avail / 1024 / 1024 / 1024)) GiB" >&2
        exit 1
    fi
fi

mkdir -p "$DEST" "$PROV"
"$HF_BIN" download "$HF_REPO" \
    --include "$IQ4_VARIANT/*" \
    --local-dir "$DEST"

count=$(find "$DEST/$IQ4_VARIANT" -maxdepth 1 -type f -name '*.gguf' | wc -l)
if [[ "$count" -ne 28 || ! -r "$FIRST" ]]; then
    echo "download-iq4: expected 28 readable GGUF shards, found $count" >&2
    exit 1
fi
find "$DEST/$IQ4_VARIANT" -maxdepth 1 -type f -name '*.gguf' -print0 \
    | sort -z | xargs -0 stat -c '%n %s' > "$PROV/iq4-model-files.txt"
sha256sum "$FIRST" > "$PROV/iq4-first-shard.sha256"
echo "download-iq4: complete: $IQ4_VARIANT ($count shards)"
