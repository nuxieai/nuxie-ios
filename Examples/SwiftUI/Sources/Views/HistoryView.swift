//
//  HistoryView.swift
//  MoodLog
//
//  Displays mood history with feature gating for Pro users.
//  Demonstrates Nuxie SDK integration for paywall presentation and event tracking in SwiftUI.
//

import SwiftUI
import Nuxie

/// Mood history view with Pro feature gating
struct HistoryView: View {

    // MARK: - Environment Objects

    @EnvironmentObject var moodStore: MoodStore
    @EnvironmentObject var entitlementManager: EntitlementManager

    // MARK: - State

    @State private var showingShareSheet = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var csvURL: URL?

    // MARK: - Computed Properties

    private var entries: [MoodEntry] {
        if entitlementManager.canAccess(.unlimitedHistory) {
            // Pro users: show all entries
            return moodStore.allEntries()
        } else {
            // Free users: show last 7 days
            return moodStore.entries(lastDays: Constants.freeHistoryLimit)
        }
    }

    private var hasMoreEntries: Bool {
        !entitlementManager.isProUser && moodStore.count > Constants.freeHistoryLimit
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack {
                Color.moodBackground.ignoresSafeArea()

                if entries.isEmpty {
                    emptyStateView
                } else {
                    listView
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if entitlementManager.canAccess(.csvExport) {
                        Button(action: handleExportTapped) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .onAppear {
                /// **Nuxie Integration: Track history_viewed event**
                NuxieSDK.shared.trigger(Constants.eventHistoryViewed, properties: [
                    "entry_count": entries.count,
                    "is_pro": entitlementManager.isProUser,
                    "timestamp": Date().timeIntervalSince1970
                ])
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = csvURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - View Components

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Text("📝")
                .font(.system(size: 64))

            Text("No mood entries yet.\nStart logging your mood today!")
                .font(.headline)
                .foregroundColor(.moodTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var listView: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry)
                        .listRowBackground(Color.moodCardBackground)
                        .listRowSeparator(.hidden)
                        .padding(.vertical, 4)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            if hasMoreEntries {
                Section {
                    unlockHistoryButton
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .background(Color.moodBackground)
    }

    private var unlockHistoryButton: some View {
        Button(action: handleUnlockHistoryTapped) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "lock.open.fill")
                            .foregroundColor(.moodPrimary)

                        Text("Unlock Full History")
                            .font(.headline)
                            .foregroundColor(.moodTextPrimary)
                    }

                    Text("Go Pro to see your complete mood history")
                        .font(.subheadline)
                        .foregroundColor(.moodTextSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.moodPrimary)
                    .font(.title3)
            }
            .padding()
            .cardStyle()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// **Nuxie Integration: CSV Export with Feature Gating**
    ///
    /// Demonstrates hard feature gating - CSV export is only available to Pro users.
    /// When free users tap export, we track an event and show a flow if configured.
    private func handleExportTapped() {
        if entitlementManager.canAccess(.csvExport) {
            // Already has Pro - export immediately
            performCSVExport()
        } else {
            /// Track gated feature attempt
            NuxieSDK.shared.trigger(Constants.eventCSVExportGated, properties: [
                "entry_count": moodStore.count,
                "source": "history_toolbar"
            ]) { [self] update in
                handleTriggerUpdate(update) {
                    self.performCSVExport()
                }
            }
        }
    }

    /// **Nuxie Integration: Unlock History Flow**
    ///
    /// Demonstrates soft feature gating - free users can see 7 days, but
    /// we show a prompt to unlock unlimited history.
    private func handleUnlockHistoryTapped() {
        NuxieSDK.shared.trigger(Constants.eventUnlockHistoryTapped, properties: [
            "visible_entries": entries.count,
            "total_entries": moodStore.count,
            "source": "history_screen"
        ]) { update in
            handleTriggerUpdate(update)
        }
    }

    /// Performs the actual CSV export
    private func performCSVExport() {
        /// Track successful export
        NuxieSDK.shared.trigger(Constants.eventExportCSV, properties: [
            "entry_count": moodStore.count
        ])

        guard let csvData = moodStore.exportCSV() else {
            errorMessage = "Failed to generate CSV"
            showingError = true
            return
        }

        // Create temporary file
        let fileName = "MoodLog-\(DateHelper.todayKey()).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csvData.write(to: tempURL)
            csvURL = tempURL
            showingShareSheet = true
        } catch {
            errorMessage = "Failed to export CSV: \(error.localizedDescription)"
            showingError = true
        }
    }

    // MARK: - Nuxie Flow Handling

    /// Handles the result of a tracked event that may trigger a flow
    private func handleTriggerUpdate(_ update: TriggerUpdate, onAllowed: (() -> Void)? = nil) {
        switch update {
        case .featureAccess(let featureAccess):
            switch featureAccess {
            case .allowed:
                onAllowed?()
            case .denied:
                errorMessage = "This is a Pro feature"
                showingError = true
            case .pending:
                break
            }
        case .decision(let decision):
            if case .noMatch = decision {
                errorMessage = "This is a Pro feature"
                showingError = true
            }
        case .error(let error):
            errorMessage = error.message
            showingError = true
        case .journey:
            break
        }
    }
}

// MARK: - Preview

struct HistoryView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryView()
            .environmentObject(MoodStore.shared)
            .environmentObject(EntitlementManager.shared)
            .environmentObject(StoreKitManager.shared)
    }
}
