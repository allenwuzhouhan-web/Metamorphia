# Phase 1 — Command Bar Prune Plan

Target file: `/Users/allenwu/claude/metamorphia/Metamorphia/components/Notch/NotchCommandBarView.swift`

Confirmed line ranges (against file at planning time, 539 lines total):

- Block 1 — Agent tree:        lines 252–255
- Block 2 — Tool pills:         lines 257–265
- Block 3 — Progress/status:    lines 267–281
- Block 4 — "Ready" badge:      lines 239–250
- Block 5 — SaveSkillBanner:    lines 57–67 (entire `#if canImport` wrapper)
- Block 6 — Stub warning call site: lines 52–56 (only the call site is removed; the
  `stubWarning` computed var at lines 140–154 stays per "leave supporting view
  definitions in place — Phase 2 will handle dead code")

---

## Coder A brief

Role: coder
Scope: remove blocks 1, 2, 3, 4 — all inside `responseBody(turn:)` starting near line 237.
Constraints: deletion only. Do not re-indent surviving code. Do not touch AgentTreeView / ToolPillsView type definitions or `toolPill(_:)` helper. Run Edit tool four times with the exact `old_string` snippets below.

### Block 4 — "Ready" badge

old_string:
```
        VStack(alignment: .leading, spacing: 8) {
            if turn.isStaged {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Ready")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }

            if let tree = viewModel.agentTree, turn.isStreaming {
```
new_string:
```
        VStack(alignment: .leading, spacing: 8) {
            if let tree = viewModel.agentTree, turn.isStreaming {
```

### Block 1 — Agent tree

old_string:
```
            if let tree = viewModel.agentTree, turn.isStreaming {
                AgentTreeView(tree: tree)
                    .transition(.opacity)
            }

            if !turn.toolPills.isEmpty {
```
new_string:
```
            if !turn.toolPills.isEmpty {
```

### Block 2 — Tool pills ScrollView

old_string:
```
            if !turn.toolPills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(turn.toolPills) { pill in
                            toolPill(pill)
                        }
                    }
                }
            }

            if turn.result.isEmpty && turn.isStreaming {
```
new_string:
```
            if turn.result.isEmpty && turn.isStreaming {
```

### Block 3 — Progress + live status

old_string:
```
            if turn.result.isEmpty && turn.isStreaming {
                // Single calm row: progress + status. Label swap uses
                // opacity only — no move-from-bottom hop.
                let label = viewModel.liveStatus ?? "Thinking…"
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.65))
                    Text(label)
                        .id(label)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)
                }
                .animation(Self.quickFade, value: label)
            } else if !turn.result.isEmpty {
```
new_string:
```
            if !turn.result.isEmpty {
```

Done when: `grep -n "agentTree\|toolPills\|liveStatus\|turn.isStaged\|\"Ready\"" NotchCommandBarView.swift` returns no matches inside the `responseBody` function body.

---

## Coder B brief

Role: coder
Scope: remove blocks 5 and 6 (call site) — header clutter at the top of `body`.
Must run AFTER Coder A. Coder B MUST Read the file fresh before editing. Use the unique `old_string` anchors below.

### Block 6 — Stub warning call site

old_string:
```
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.isStubMode {
                stubWarning
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
#if canImport(MetamorphiaAgentKit)
```
new_string:
```
        VStack(alignment: .leading, spacing: 0) {
#if canImport(MetamorphiaAgentKit)
```

Do NOT delete the `stubWarning` computed property (~lines 140–154 pre-shift). Leave it — Phase 2 sweeps dead code.

### Block 5 — SaveSkillBannerView wrapper

old_string:
```
#if canImport(MetamorphiaAgentKit)
            if let proposal = viewModel.pendingSkillProposal {
                SaveSkillBannerView(
                    proposal: proposal,
                    onSave: { name in viewModel.savePendingSkill(as: name) },
                    onDismiss: { viewModel.dismissSkillProposal() }
                )
                .padding(.bottom, 8)
                .transition(.opacity)
            }
#endif

            inputRow
```
new_string:
```
            inputRow
```

Note: removes the `#if canImport(MetamorphiaAgentKit)` … `#endif` block that wraps ONLY the SaveSkillBanner (the later `#if canImport` wrapping `slashSuggestions` at ~line 76 is a different block and MUST stay).

Done when: `grep -n "SaveSkillBannerView\|isStubMode\|stubWarning" NotchCommandBarView.swift` shows zero hits in `body`; `stubWarning` computed var still exists below the `// MARK: - Stub warning` marker.

---

## Sequencing

Coder A first (4 deletions in `responseBody`). Coder B after A, re-Reads file first. Both edit the same file; cannot parallelize. Critic runs last.
