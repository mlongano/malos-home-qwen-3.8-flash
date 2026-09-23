#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.env
source "$ROOT/config.env"
DEST="$ROOT/models/unsloth-Qwen3.8-Flash-Next-GGUF"
PROV="$ROOT/provenance"
TARGET="$DEST/$MTP_FILE"

if [[ ! -x "$HF_BIN" ]]; then
    echo "download-mtp: Hugging Face client is missing: $HF_BIN" >&2
    exit 1
fi

mkdir -p "$DEST" "$PROV"
"$HF_BIN" download "$MTP_REPO" \
    --include "$MTP_FILE" \
    --local-dir "$DEST"

if [[ ! -r "$TARGET" ]]; then
    echo "download-mtp: expected file is missing: $TARGET" >&2
    exit 1
fi
sha256sum "$TARGET" > "$PROV/mtp.sha256"
stat -c '%n %s' "$TARGET" > "$PROV/mtp-file.txt"
echo "download-mtp: complete: $TARGET"
