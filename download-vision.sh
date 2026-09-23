#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=config.env
source "$ROOT/config.env"
DEST="$ROOT/models"
PROV="$ROOT/provenance"
TARGET="$DEST/$MMPROJ_FILE"

if [[ ! -x "$HF_BIN" ]]; then
    echo "download-vision: Hugging Face client is missing: $HF_BIN" >&2
    exit 1
fi

mkdir -p "$DEST" "$PROV"
"$HF_BIN" download "$HF_REPO" \
    --include "$MMPROJ_FILE" \
    --local-dir "$DEST"

if [[ ! -r "$TARGET" ]]; then
    echo "download-vision: expected file is missing: $TARGET" >&2
    exit 1
fi
actual=$(sha256sum "$TARGET" | awk '{print $1}')
if [[ "$actual" != "$MMPROJ_SHA256" ]]; then
    echo "download-vision: SHA-256 mismatch: expected $MMPROJ_SHA256, found $actual" >&2
    exit 1
fi
sha256sum "$TARGET" > "$PROV/mmproj.sha256"
stat -c '%n %s' "$TARGET" > "$PROV/mmproj-file.txt"
echo "download-vision: complete: $TARGET"
