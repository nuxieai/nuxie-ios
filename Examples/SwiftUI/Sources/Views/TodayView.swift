//
//  TodayView.swift
//  MoodLog
//
//  Main mood entry screen demonstrating Nuxie SDK integration in SwiftUI.
//  Shows event tracking, flow handling, and state management patterns.
//

import SwiftUI
import Nuxie

/// Main mood entry view
struct TodayView: View {

    // MARK: - Environment Objects

    @EnvironmentObject var moodStore: MoodStore
    @EnvironmentObject var entitlementManager: EntitlementManager

    // MARK: - State

    @State private var selectedMood: Int?
    @State private var noteText: String = ""
    @State private var showingSuccess = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var shake = 0

    // MARK: - Computed Properties

    private var todayEntry: MoodEntry? {
        moodStore.todayEntry()
    }

    private var streak: Int {
        moodStore.calculateStreak()
    }

    private var canSave: Bool {
        selectedMood != nil && Constants.moodRange.contains(selectedMood!)
    }

    private var characterCount: Int {
        noteText.count
    }

    private var charactersRemaining: Int {
        Constants.maxNoteLength - characterCount
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Constants.largePadding) {
                    // Header
                    headerSection

                    // Streak display
                    if streak > 0 {
                        StreakView(streak: streak)
                            .bounceAnimation(delay: 0.1)
                    }

                    // Mood selection
                    moodSelectionSection

                    // Note input
                    noteInputSection

                    // Save button
                    saveButton

                    Spacer()
                }
                .padding(Constants.standardPadding)
            }
            .background(Color.moodBackground.ignoresSafeArea())
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !entitlementManager.isProUser {
                        Button(action: handleGoProTapped) {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                Text("Pro")
                                    .font(.subheadline.bold())
                            }
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.moodProGradientStart, .moodProGradientEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        }
                    }
                }
            }
            .onAppear {
                loadTodayEntry()
            }
            .alert("Success!", isPresented: $showingSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your mood has been saved!")
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text(DateHelper.displayString(from: DateHelper.todayKey()))
                .font(.headline)
                .foregroundColor(.moodTextSecondary)

            Text(todayEntry == nil ? "How are you feeling?" : "Update your mood")
                .font(.title2.bold())
                .foregroundColor(.moodTextPrimary)
                .multilineTextAlignment(.center)
        }
    }

    private var moodSelectionSection: some View {
        VStack(spacing: 12) {
            Text("Select Your Mood")
                .font(.subheadline.bold())
                .foregroundColor(.moodTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { mood in
                    MoodButton(
                        mood: mood,
                        isSelected: selectedMood == mood
                    ) {
                        handleMoodSelection(mood)
                    }
                }
            }
        }
        .padding()
        .cardStyle()
        .bounceAnimation(delay: 0.2)
    }

    private var noteInputSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add a Note (Optional)")
                    .font(.subheadline.bold())
                    .foregroundColor(.moodTextSecondary)

                Spacer()

                Text("\(charactersRemaining)")
                    .font(.caption)
                    .foregroundColor(charactersRemaining < 20 ? .moodWarning : .moodTextTertiary)
            }

            TextEditor(text: $noteText)
                .frame(height: 100)
                .padding(8)
                .background(Color.moodTertiaryBackground)
                .cornerRadius(8)
                .foregroundColor(.moodTextPrimary)
                .onChange(of: noteText) { newValue in
                    // Limit to max length
                    if newValue.count > Constants.maxNoteLength {
                        noteText = String(newValue.prefix(Constants.maxNoteLength))
                    }
                }
        }
        .padding()
        .cardStyle()
        .bounceAnimation(delay: 0.25)
    }

    private var saveButton: some View {
        Button(action: saveMood) {
            HStack {
                Image(systemName: todayEntry == nil ? "plus.circle.fill" : "arrow.clockwise.circle.fill")
                Text(todayEntry == nil ? "Save Mood" : "Update Mood")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(canSave ? Color.moodPrimary : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .cornerRadius(Constants.cornerRadius)
        }
        .disabled(!canSave)
        .shake(with: shake)
        .bounceAnimation(delay: 0.3)
    }

    // MARK: - Actions

    private func loadTodayEntry() {
        if let entry = todayEntry {
            selectedMood = entry.mood
            noteText = entry.note ?? ""
        }
    }

    /// **Nuxie Integration: Mood Selection Event**
    ///
    /// Track when user taps a mood emoji (before saving).
    /// This helps identify drop-off: users who select but don't save.
    private func handleMoodSelection(_ mood: Int) {
        selectedMood = mood

        /// Track mood selection event
        NuxieSDK.shared.trigger(Constants.eventMoodSelected, properties: [
            "mood": mood,
            "mood_emoji": Constants.moodEmojis[mood] ?? "",
            "mood_label": Constants.moodLabels[mood] ?? "",
            "has_existing_entry": todayEntry != nil,
            "current_streak": streak
        ])

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    /// **Nuxie Integration: Mood Saved Event**
    ///
    /// Track when user successfully saves a mood entry.
    /// This is your core engagement metric.
    private func saveMood() {
        guard let mood = selectedMood else {
            shake += 1
            return
        }

        let entry = MoodEntry(
            date: DateHelper.todayKey(),
            mood: mood,
            note: noteText.isEmpty ? nil : noteText
        )

        do {
            try moodStore.save(entry)

            /// Track mood saved event
            NuxieSDK.shared.trigger(Constants.eventMoodSaved, properties: [
                "mood": mood,
                "mood_emoji": Constants.moodEmojis[mood] ?? "",
                "has_note": entry.hasNote,
                "note_length": noteText.count,
                "is_update": todayEntry != nil,
                "streak": moodStore.calculateStreak(),
                "total_entries": moodStore.count
            ])

            showingSuccess = true

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    /// **Nuxie Integration: Upgrade Flow Trigger**
    ///
    /// When user taps "Go Pro", track the event and let Nuxie decide
    /// whether to show a flow based on dashboard configuration.
    private func handleGoProTapped() {
        NuxieSDK.shared.trigger(Constants.eventUpgradeTapped, properties: [
            "source": "today_screen",
            "current_streak": streak,
            "total_entries": moodStore.count
        ]) { update in
            handleTriggerUpdate(update)
        }
    }

    // MARK: - Nuxie Flow Handling

    /// Handles the result of a tracked event that may trigger a flow
    private func handleTriggerUpdate(_ update: TriggerUpdate) {
        switch update {
        case .entitlement(let entitlement):
            switch entitlement {
            case .allowed:
                print("[MoodLog] Pro unlocked! 🎉")
            case .denied:
                errorMessage = "Access denied."
                showingError = true
            case .pending:
                break
            }
        case .decision(let decision):
            if case .noMatch = decision {
                print("[MoodLog] No flow shown - configure an experience in Nuxie dashboard")
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

struct TodayView_Previews: PreviewProvider {
    static var previews: some View {
        TodayView()
            .environmentObject(MoodStore.shared)
            .environmentObject(EntitlementManager.shared)
            .environmentObject(StoreKitManager.shared)
    }
}
