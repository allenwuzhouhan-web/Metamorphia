# Critique — Phase 1 Command Bar Prune

## Verdict
PASS-WITH-CONCERNS

## Score
8.5 / 10

## Checklist results

Removal confirmations (all grepped independently against the current file):
- `viewModel.agentTree` — ✓ 0 hits
- `AgentTreeView(tree:` — ✓ 0 hits
- `turn.toolPills` — ✓ 0 hits
- `ForEach(turn.toolPills)` — ✓ 0 hits
- `viewModel.liveStatus` — ✓ 0 hits
- `"Thinking…"` — ✓ 0 hits
- `turn.isStaged` — ✓ 0 hits
- `"Ready"` inside `responseBody` — ✓ 0 hits anywhere in file
- `SaveSkillBannerView(` — ✓ 0 hits
- `viewModel.pendingSkillProposal` — ✓ 1 hit at line 117 (inside `body`'s `.animation(..., value:)` modifier — explicitly allowed by success_criteria.md line 27)
- `savePendingSkill` — ✓ 0 hits
- `dismissSkillProposal` — ✓ 0 hits
- `viewModel.isStubMode` — ✓ 0 hits
- `stubWarning` called inside `body` — ✓ 0 hits (definition at line 123 still present, as allowed)

Structural integrity:
- Brace balance — ✓ `body` opens L50, closes L119; `responseBody` opens L220, closes L298; inner VStack L221→L297. All balanced.
- Block 3 collapse — ✓ Line 222 reads `if !turn.result.isEmpty {` — the former `else if` became a bare `if` exactly as required.
- `#if canImport(MetamorphiaAgentKit)` around `SkillSuggestionListView` — ✓ still present (L59–L69).

Preserved surface area:
- `inputRow` — ✓ L141 unchanged
- `SkillSuggestionListView` — ✓ unchanged
- `StreamingResponseText` scroll body — ✓ L229–L277 unchanged
- `FunctionGraphView` block — ✓ L280–L283 unchanged
- Error row — ✓ L285–L296 unchanged
- `stubWarning` computed property — ✓ L123 still present
- `toolPill(_:)` and `toolSymbol(for:)` — ✓ both still present (L300, L318)

File-size delta: 539 → 479 = −60 lines.

## Issues found

- minor — `NotchCommandBarView.swift:300-314, :318-333` — `toolPill(_:)` and `toolSymbol(for:)` are now unreferenced dead helpers. Per-plan (Phase 2 sweep). Note: `toolPill` transitively keeps `AICommandViewModel.ToolCallPill` referenced from this file — if Phase 2 removes the type, this file breaks first. Fix: in Phase 2, remove helpers together.
- minor — `:117` — `.animation(Self.fluidSpring, value: viewModel.pendingSkillProposal)` retained but SaveSkillBanner no longer renders. Harmless but noise. Plan permits leaving it. Fix: Phase 2.
- nit — `:121` — `// MARK: - Stub warning` header precedes a now-uncalled computed property. Cosmetic. Fix: Phase 2.

No blockers. No high-severity or major issues.

## Things the coders did well
- All grep removal checks verified independently; coders' self-reports were accurate.
- Block 3's `else if → if` collapse is clean.
- No stranded comments or orphan blank lines.
- Coder B correctly preserved the second `#if canImport(MetamorphiaAgentKit)` wrapper around `SkillSuggestionListView`.
- Brace balance is perfect across both edited scopes.

## Open questions for the editor
- Line delta is −60 vs. the 45–55 estimate. Attributable to natural collapse of blank-line separators between adjacent deleted blocks.
- Plan defers `toolPill`/`toolSymbol`/`stubWarning` dead-code removal to Phase 2. Confirm Phase 2 is queued.
- `viewModel.pendingSkillProposal` on L117: could be argued as pure noise now.
- Supporting type definition files (`AgentTreeView`, `ToolPillsView`, `SaveSkillBannerView` in their own files) not independently verified — trusted via plan's single-file-scope claim.
