# CommandBar — intentionally empty

The AI Command Bar does **not** live in this directory. The actual
implementation is split across three files:

- `Metamorphia/Coordinators/CommandBarCoordinator.swift` — summon/dismiss/toggle
  wiring, per-screen notch resolution, window-key handoff.
- `Metamorphia/components/Notch/NotchCommandBarView.swift` — the SwiftUI
  view rendered inside the existing notch when
  `coordinator.currentView == .commandBar`.
- `Metamorphia/ViewModels/AICommandViewModel.swift` — the @ObservableObject
  that holds conversation state and bridges to `MetamorphiaAgentKit`'s `AgentLoop`.

This folder is kept only so the Xcode project group reference resolves. If
the Xcode project is ever cleaned up to drop the empty reference, this
directory can be removed outright.
