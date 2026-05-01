# Editor Audit — Critic's Phase 1 Review

## Verdict on the critic
MOSTLY-ACCURATE

## Critic's score adjustment
Critic gave 8.5/10. My adjusted score: 8/10 because the critic missed a now-dead `import AppKit` (NotchCommandBarView.swift:2), fudged the file-size delta by one line (478 lines, not 479 → −61, not −60), and punted the cross-file type-definition check to "open questions" when a single grep would have resolved it.

## Critic claims verified
- All 14 removal-confirmation rows: verified via grep. Zero hits for `viewModel.agentTree`, `AgentTreeView(`, `turn.toolPills`, `viewModel.liveStatus`, `"Thinking"`, `turn.isStaged`, `"Ready"`, `SaveSkillBannerView(`, `savePendingSkill`, `dismissSkillProposal`, `viewModel.isStubMode`. Holds up.
- `viewModel.pendingSkillProposal` — exactly 1 hit at NotchCommandBarView.swift:117, inside the `.animation(...)` modifier on `body`. Matches critic.
- `stubWarning` — 1 hit at NotchCommandBarView.swift:123 (definition). No call site in `body`. Holds up.
- Block 3 collapse: NotchCommandBarView.swift:222 reads `if !turn.result.isEmpty {` — clean, no stranded `else`. Holds up.
- `body` opens L50, closes L119; `responseBody` opens L220, closes L298. Holds up.
- `#if canImport(MetamorphiaAgentKit)` around `SkillSuggestionListView` present at L59–L69. Holds up.
- `toolPill(_:)` at L300 and `toolSymbol(for:)` at L318 still present. Holds up.
- `responseBody` still reachable from `body` at NotchCommandBarView.swift:72. Sanity check passes.
- Supporting types in other files untouched: `AgentTreeView` (AgentTreeView.swift:12), `AgentTreeSnapshot` (AgentNode.swift:56), `SaveSkillBannerView` (SaveSkillBannerView.swift:10), `ToolCallPill` (AICommandViewModel.swift:56), `pendingSkillProposal` (AICommandViewModel.swift:126) — all intact. Critic flagged this as unverified open question; it's fine.

## Critic false positives
None. Every flagged issue corresponds to real post-prune residue.

## Critic misses
- **Dead import** — NotchCommandBarView.swift:2 `import AppKit` has no remaining AppKit symbol usage in the file (grep for NSApp/NSColor/NSView/NSWindow/NSEvent/NSImage/NSFont/NSScreen/NSWorkspace/NSCursor/NSPasteboard/NSResponder: 0 hits beyond the import line itself). Candidate for Phase 2 removal.
- **Line-count arithmetic off-by-one** — file is 478 lines (wc -l), not 479; delta is −61, not −60.
- **Punted verification** — critic's open question "Supporting type definition files not independently verified" was resolvable by one grep; the types are intact. Leaving it open is hedging, not substance.

## Severity calibration
- `toolPill`/`toolSymbol` dead helpers (minor) — appropriate. The transitive-dependency warning about `AICommandViewModel.ToolCallPill` is a real Phase-2 sequencing note, well-calibrated.
- `.animation(..., value: viewModel.pendingSkillProposal)` at :117 (minor) — appropriate. Success criteria explicitly permits leaving it.
- `// MARK: - Stub warning` header (nit) — appropriate.
- Missed `import AppKit` should have been minor (same tier as the other Phase-2 dead-code notes).

## Ready-to-ship recommendation
SHIP

Phase 1 goals are fully met: every removal confirmed, structural integrity intact, preserved surface area untouched, no cross-file collateral. Residual dead helpers/imports are explicitly Phase 2 scope. The critic was thorough on the core removal checklist; the miss (dead `import AppKit`) and hedging (unverified cross-file types) are minor and do not block ship.
