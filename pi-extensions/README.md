# Remote compaction extension (staged: not installed, not tested)

`remote-compaction.ts` replaces Pi's local compaction request with:

1. `github-copilot/gemini-3.6-flash`
2. `opencode-go/qwen3.8-flash` fallback
3. Pi's default compaction if both are unavailable

It caps summaries at 4,096 tokens, disables reasoning, removes serialized assistant thinking,
deduplicates identical tool results, and stores cumulative file operations in compaction
`details` rather than repeating inventories in the summary.

## Privacy gate

**Decision on 2026-09-21: keep this documented as an available option, but do not install or test
it.** No conversation data has been sent to a remote compactor and none will be until the user
reopens this. The file is staged only in this project and has not been copied into
`~/.pi/agent/extensions/`.

The only validation performed so far is static: `bun build` compiles the module and
`pi --extension` loads it while listing models. That exercises no compaction path and touches no
session.

## If this is ever reopened

Test on a copied session branch first, never in the live session:

```sh
pi --extension "$PWD/pi-extensions/remote-compaction.ts"
```

Then trigger `/compact` in the copy and inspect the resulting JSONL compaction entry for provider,
output length, file-operation `details` and continuation quality before considering a global
install. Until then, compaction stays on Pi's default path against the local model.
