/*
 * Metamorphia
 * Continuum Phase 13 — Settings & kill switches.
 *
 * Exposes all Continuum feature flags in one pane so the user can turn any
 * piece off, inspect what the app has learned, and wipe everything if desired.
 */

import Defaults
import MetamorphiaAgentKit
import MetamorphiaPerception
import SwiftUI

// MARK: - ContinuumSettingsView

struct ContinuumSettingsView: View {

    @Default(.newsEnabled)                  private var newsEnabled
    @Default(.newsMorningBriefEnabled)      private var morningBriefEnabled
    @Default(.newsClipboardEnrichmentEnabled) private var clipboardEnrichmentEnabled
    @Default(.newsMeetingPreBriefsEnabled)  private var meetingPreBriefsEnabled
    @Default(.newsPredictiveStagingEnabled) private var predictiveStagingEnabled
    @Default(.attentionModelEnabled)        private var attentionModelEnabled
    @Default(.workflowRecorderEnabled)      private var workflowRecorderEnabled

    @State private var showInterestGraph = false
    @State private var showForgetConfirmation = false
    @State private var calendarPermissionGranted = false

    var body: some View {
        header

        newsSurfacesSection

        learningSection

        calendarSection

        dangerZoneSection
            .sheet(isPresented: $showInterestGraph) {
                InterestGraphInspector()
            }
            .alert("Forget everything?", isPresented: $showForgetConfirmation) {
                Button("Forget everything", role: .destructive) {
                    Task { await forgetAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your interest graph, attention model, story history, and learned query patterns. Continuum will start fresh. This cannot be undone.")
            }
            .onAppear {
                calendarPermissionGranted = CalendarLens.shared.permissionGranted
            }
            .onReceive(CalendarLens.shared.$permissionGranted) { granted in
                calendarPermissionGranted = granted
            }
    }

    // MARK: - Header

    private var header: some View {
        Section {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Continuum")
                    .font(.headline)
                Spacer()
            }
            Text("Metamorphia quietly learns what you care about and continues threads you've already started. You can turn any piece off, or inspect what it knows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - News surfaces

    private var newsSurfacesSection: some View {
        Section("News surfaces") {
            Toggle("News", isOn: $newsEnabled)

            if newsEnabled {
                Group {
                    Toggle("Morning brief", isOn: $morningBriefEnabled)
                    Toggle("Clipboard hints", isOn: $clipboardEnrichmentEnabled)
                    Toggle("Meeting pre-briefs", isOn: $meetingPreBriefsEnabled)
                    Toggle("Predictive staging", isOn: $predictiveStagingEnabled)
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Learning

    private var learningSection: some View {
        Section("Learning") {
            Toggle("Attention model", isOn: $attentionModelEnabled)
            Text("Learns the hours you tend to use Metamorphia and suppresses proactive surfaces during low-engagement windows.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Learn from my repeated tasks", isOn: $workflowRecorderEnabled)
                .onChange(of: workflowRecorderEnabled) { _, newValue in
                    Task { await SkillRecorder.shared.setEnabled(newValue) }
                }
            Text("Watches your successful multi-step actions and offers to turn frequently-repeated sequences into one-tap tools. No data leaves your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Inspect interest graph") {
                showInterestGraph = true
            }
        }
    }

    // MARK: - Calendar

    private var calendarSection: some View {
        Section("Calendar") {
            if calendarPermissionGranted {
                HStack {
                    Text("Calendar access")
                    Spacer()
                    Text("Granted")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Request calendar access")
                        Text("Needed for meeting pre-briefs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow") {
                        Task { await CalendarLens.shared.requestAccess() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Danger zone

    private var dangerZoneSection: some View {
        Section("Danger zone") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forget everything")
                    Text("Wipes the interest graph, attention model, story history, and query patterns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget everything", role: .destructive) {
                    showForgetConfirmation = true
                }
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Wipe action

    @MainActor
    private func forgetAll() async {
        await MetamorphiaBootstrap.interestGraph?.forgetAll()
        await MetamorphiaBootstrap.stories?.forgetAll()
        AttentionModel.shared.forgetAll()
        QueryPatternLearner.shared.forgetAll()
    }
}
