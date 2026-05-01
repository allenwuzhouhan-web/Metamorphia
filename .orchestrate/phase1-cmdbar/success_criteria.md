# Phase 1 Success Criteria — Critic Checklist

Target file: `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`

## Removal confirmations (grep inside NotchCommandBarView.swift)

- [ ] `viewModel.agentTree` — 0 hits
- [ ] `AgentTreeView(tree:` — 0 hits
- [ ] `turn.toolPills` — 0 hits
- [ ] `ForEach(turn.toolPills)` — 0 hits
- [ ] `viewModel.liveStatus` — 0 hits
- [ ] `"Thinking…"` — 0 hits
- [ ] `turn.isStaged` — 0 hits
- [ ] `"Ready"` string literal — 0 hits inside `responseBody`
- [ ] `SaveSkillBannerView(` — 0 hits (call site)
- [ ] `viewModel.pendingSkillProposal` — 0 hits in `body`
- [ ] `savePendingSkill` — 0 hits
- [ ] `dismissSkillProposal` — 0 hits
- [ ] `viewModel.isStubMode` — 0 hits
- [ ] `stubWarning` called inside `body` — 0 hits (the computed var definition itself may still exist; that's expected)

## Structural integrity

- [ ] Brace balance: every `{` has a matching `}`. No orphan `if` with empty body, no dangling `else`.
- [ ] Block 3 specifically: `if turn.result.isEmpty && turn.isStreaming` is gone; the former `else if !turn.result.isEmpty` has become a bare `if !turn.result.isEmpty`.
- [ ] The `#if canImport(MetamorphiaAgentKit)` that wraps `SkillSuggestionListView` (slash suggestions) is still present.
- [ ] The `.animation(Self.fluidSpring, value: viewModel.pendingSkillProposal)` modifier — acceptable to leave untouched in Phase 1 since removing widens scope.

## Preserved surface area

- [ ] Input row (SiriOrbView + TextField + trailingControl) — present and unchanged
- [ ] Skill suggestions dropdown (`SkillSuggestionListView`) — present and unchanged
- [ ] `StreamingResponseText` scroll body — present and unchanged
- [ ] `FunctionGraphView` render block — present and unchanged
- [ ] Error row (`if let err = viewModel.errorMessage`) — present and unchanged
- [ ] Supporting view type definitions (`AgentTreeView`, `ToolPillsView`, `SaveSkillBannerView`) in their OWN files — untouched
- [ ] `stubWarning` computed property — still exists in file
- [ ] `toolPill(_:)` helper method and `toolSymbol(for:)` helper — still exist in file

## Out-of-scope guard

- [ ] No edits to `AICommandViewModel.swift`
- [ ] No edits to `CommandBarCoordinator.swift`
- [ ] No edits to any file other than `NotchCommandBarView.swift`
- [ ] No rename, no refactor, no reformatting — deletion only

## Compile sanity (inspection only)

- [ ] No reference to removed symbols remains in `NotchCommandBarView.swift`
- [ ] All `@ViewBuilder` / computed property return types still produce `some View`
- [ ] No unused `let label = …` or similar residue from block 3

## Expected file-size delta

Roughly 45–55 fewer lines than the 539-line baseline.
