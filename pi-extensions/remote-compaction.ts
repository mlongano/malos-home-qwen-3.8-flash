import { uuidv7 } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";

const COMPACTORS = [
	["github-copilot", "gemini-3.6-flash"],
	["opencode-go", "qwen3.8-flash"],
] as const;

export function pruneSerializedConversation(text: string): string {
	const withoutThinking = text.replace(
		/(?:^|\n)\[Assistant thinking\]:[\s\S]*?(?=\n\[(?:User|Assistant|Assistant tool calls|Tool result)\]:|$)/g,
		"",
	);
	const seen = new Set<string>();
	return withoutThinking.replace(
		/(^|\n)(\[Tool result\]:[\s\S]*?)(?=\n\[(?:User|Assistant|Assistant tool calls|Tool result)\]:|$)/g,
		(match, prefix: string, block: string) => {
			const key = block.trim();
			if (!seen.has(key)) {
				seen.add(key);
				return match;
			}
			return `${prefix}[Tool result]: [duplicate omitted]`;
		},
	).trim();
}

function summaryPrompt(conversation: string, previousSummary?: string, instructions?: string): string {
	return `Create a compact continuation summary for a coding agent. Preserve only information needed to resume work accurately.

Required sections:
## Goal
## Constraints & Preferences
## Progress
### Done
### In Progress
### Blocked
## Key Decisions
## Next Steps
## Critical Context

Rules:
- Target 2,000-4,000 tokens and never pad.
- Preserve exact commands, measurements, identifiers, errors and rollback state when operationally important.
- Preserve unresolved user requests and the current active state.
- Omit chain-of-thought, repeated history, routine successful tool output and conversational filler.
- Do not emit read-files or modified-files inventories; those are stored separately in compaction details.
- Reconcile the previous summary with newer evidence instead of repeating both.
${instructions ? `- Additional instruction: ${instructions}\n` : ""}
${previousSummary ? `<previous-summary>\n${previousSummary}\n</previous-summary>\n` : ""}
<conversation>
${conversation}
</conversation>`;
}

export default function remoteCompaction(pi: ExtensionAPI) {
	pi.on("session_before_compact", async (event, ctx) => {
		const { preparation, customInstructions, signal } = event;
		const allMessages = [...preparation.messagesToSummarize, ...preparation.turnPrefixMessages];
		const conversation = pruneSerializedConversation(serializeConversation(convertToLlm(allMessages)));
		const prompt = summaryPrompt(conversation, preparation.previousSummary, customInstructions);

		for (const [provider, modelId] of COMPACTORS) {
			if (signal.aborted) return;
			const model = ctx.modelRegistry.find(provider, modelId);
			if (!model || !ctx.modelRegistry.hasConfiguredAuth(model)) continue;
			try {
				if (ctx.hasUI) ctx.ui.notify(`Compacting with ${provider}/${modelId}`, "info");
				const response = await ctx.modelRegistry.complete(
					model,
					{ messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }] },
					{
						maxTokens: 4096,
						reasoningEffort: "off",
						cacheRetention: "none",
						sessionId: uuidv7(),
						signal,
					},
				);
				const summary = response.content
					.filter((part): part is { type: "text"; text: string } => part.type === "text")
					.map((part) => part.text)
					.join("\n")
					.trim();
				if (!summary) throw new Error("empty compaction summary");
				return {
					compaction: {
						summary,
						firstKeptEntryId: preparation.firstKeptEntryId,
						tokensBefore: preparation.tokensBefore,
						usage: response.usage,
						details: {
							...preparation.fileOps,
							compactor: `${provider}/${modelId}`,
							inputCharacters: conversation.length,
							thinkingRemoved: true,
						},
					},
				};
			} catch (error) {
				if (signal.aborted) return;
				if (ctx.hasUI) {
					const message = error instanceof Error ? error.message : String(error);
					ctx.ui.notify(`${provider}/${modelId} compaction failed: ${message}`, "warning");
				}
			}
		}
		if (ctx.hasUI) ctx.ui.notify("Remote compactors unavailable; using default compaction", "warning");
		return;
	});
}
