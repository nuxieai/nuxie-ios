//
//  TodayViewController.swift
//  MoodLog
//
//  Main screen for logging today's mood.
//  Demonstrates Nuxie SDK event tracking and user interaction patterns.
//

import UIKit
import Nuxie

final class TodayViewController: UIViewController {

    // MARK: - Properties

    private var selectedMood: Int?
    private let moodStore = MoodStore.shared
    private let entitlementManager = EntitlementManager.shared

    // MARK: - UI Components

    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        return scrollView
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Constants.largePadding
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "How are you today?"
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textColor = .moodTextPrimary
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let moodButtonsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let noteTextField: UITextField = {
        let textField = UITextField()
        textField.placeholder = "Add a note (optional)"
        textField.font = .systemFont(ofSize: 16)
        textField.textColor = .moodTextPrimary
        textField.borderStyle = .none
        textField.backgroundColor = .moodCardBackground
        textField.layer.cornerRadius = Constants.cornerRadius
        textField.translatesAutoresizingMaskIntoConstraints = false

        // Add padding
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 0))
        textField.leftView = paddingView
        textField.leftViewMode = .always
        textField.rightView = paddingView
        textField.rightViewMode = .always

        return textField
    }()

    private lazy var saveButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Save Mood", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = .moodPrimary
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = Constants.cornerRadius
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(saveButtonTapped), for: .touchUpInside)
        button.isEnabled = false
        button.alpha = 0.5
        return button
    }()

    private let streakView = StreakView()

    private lazy var historyButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("View History →", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.setTitleColor(.moodPrimary, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(historyButtonTapped), for: .touchUpInside)
        return button
    }()

    private var moodButtons: [MoodButton] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setup()
        loadTodayEntry()

        /// **Nuxie Integration: Track view event**
        /// Track when user opens the Today screen
        NuxieSDK.shared.trigger(Constants.eventAppOpened, properties: [
            "launch_date": Date().timeIntervalSince1970,
            "screen": "today"
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateProBadge()
        updateStreakView()
    }

    // MARK: - Setup

    private func setup() {
        view.backgroundColor = .moodBackground
        title = "MoodLog"

        // Setup scroll view
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        // Create mood buttons
        for mood in 1...5 {
            let button = MoodButton(moodValue: mood)
            button.addTarget(self, action: #selector(moodButtonTapped(_:)), for: .touchUpInside)
            moodButtons.append(button)
            moodButtonsStack.addArrangedSubview(button)
        }

        // Build content stack
        contentStack.addArrangedSubviews([
            titleLabel,
            moodButtonsStack,
            noteTextField,
            saveButton,
            streakView,
            historyButton
        ])

        // Add spacing views
        contentStack.setCustomSpacing(32, after: titleLabel)
        contentStack.setCustomSpacing(32, after: moodButtonsStack)
        contentStack.setCustomSpacing(32, after: saveButton)

        // Layout
        NSLayoutConstraint.activate([
            // Scroll view
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // Content stack
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: Constants.largePadding),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: Constants.largePadding),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -Constants.largePadding),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -Constants.largePadding),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -Constants.largePadding * 2),

            // Note text field height
            noteTextField.heightAnchor.constraint(equalToConstant: 50),

            // Save button height
            saveButton.heightAnchor.constraint(equalToConstant: 54)
        ])

        // Streak view doesn't need extra constraints - it's in the stack
        streakView.translatesAutoresizingMaskIntoConstraints = false

        // Text field delegate
        noteTextField.delegate = self
        noteTextField.addTarget(self, action: #selector(noteTextChanged), for: .editingChanged)

        // Keyboard handling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        // Tap to dismiss keyboard
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)
    }

    private func updateProBadge() {
        if entitlementManager.isProUser {
            // Show Pro badge in nav bar
            let badge = UILabel()
            badge.text = "PRO"
            badge.font = .systemFont(ofSize: 12, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = .moodProGradientStart
            badge.layer.cornerRadius = 8
            badge.clipsToBounds = true
            badge.textAlignment = .center
            badge.frame = CGRect(x: 0, y: 0, width: 40, height: 24)
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: badge)
        } else {
            // Show "Go Pro" button
            let button = UIButton(type: .system)
            button.setTitle("Go Pro", for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = .moodAccent
            button.layer.cornerRadius = 8
            button.frame = CGRect(x: 0, y: 0, width: 65, height: 28)
            button.addTarget(self, action: #selector(goProTapped), for: .touchUpInside)
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: button)
        }
    }

    private func updateStreakView() {
        let streak = moodStore.calculateStreak()
        streakView.updateStreak(streak, animated: true)
    }

    // MARK: - Data Loading

    private func loadTodayEntry() {
        if let todayEntry = moodStore.todayEntry() {
            // Pre-select mood
            selectedMood = todayEntry.mood
            updateMoodSelection()

            // Pre-fill note
            noteTextField.text = todayEntry.note

            // Update button state
            updateSaveButtonState()
        }
    }

    // MARK: - Actions

    @objc private func moodButtonTapped(_ sender: MoodButton) {
        selectedMood = sender.moodValue

        /// **Nuxie Integration: Track mood selection**
        /// Track when user selects a mood (before saving) to understand
        /// engagement and where users drop off in the flow
        NuxieSDK.shared.trigger(Constants.eventMoodSelected, properties: [
            "mood": sender.moodValue,
            "mood_emoji": Constants.moodEmojis[sender.moodValue] ?? "",
            "mood_label": Constants.moodLabels[sender.moodValue] ?? "",
            "has_existing_entry": moodStore.todayEntry() != nil,
            "current_streak": moodStore.calculateStreak()
        ])

        /// Provide immediate feedback for better UX
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()

        updateMoodSelection()
        updateSaveButtonState()

        // Animate selection
        sender.animateSelection()
    }

    @objc private func saveButtonTapped() {
        guard let mood = selectedMood else { return }

        // Trim note
        let note = noteTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNote = !(note?.isEmpty ?? true)

        // Check if updating existing entry
        let isUpdate = moodStore.todayEntry() != nil

        // Create entry
        let entry = MoodEntry(
            date: DateHelper.todayKey(),
            mood: mood,
            note: hasNote ? note : nil
        )

        do {
            // Save entry
            try moodStore.save(entry)

            // Calculate new streak
            let newStreak = moodStore.calculateStreak()

            /// **Nuxie Integration: Track mood_saved event**
            /// This is a key engagement event - track detailed properties
            /// to understand user behavior and identify conversion opportunities
            NuxieSDK.shared.trigger(Constants.eventMoodSaved, properties: [
                "mood": mood,
                "mood_emoji": Constants.moodEmojis[mood] ?? "",
                "mood_label": Constants.moodLabels[mood] ?? "",
                "has_note": hasNote,
                "note_length": note?.count ?? 0,
                "is_update": isUpdate,
                "streak": newStreak,
                "streak_increased": !isUpdate, // Only increases on new entries
                "total_entries": moodStore.count
            ])

            // Update UI
            updateStreakView()

            // Provide feedback
            let feedback = UINotificationFeedbackGenerator()
            feedback.notificationOccurred(.success)

            // Show success message
            showSuccessMessage()

        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func historyButtonTapped() {
        let historyVC = HistoryViewController()
        navigationController?.pushViewController(historyVC, animated: true)
    }

    @objc private func goProTapped() {
        /// **Nuxie Integration: Event-Driven Paywalls**
        /// Instead of showing a hardcoded paywall, we track an event and let
        /// Nuxie's backend decide whether to show a flow based on experiences
        /// configured in the dashboard.
        ///
        /// The handler receives TriggerUpdate events with decisions and entitlements
        NuxieSDK.shared.trigger("upgrade_tapped", properties: [
            "source": "today_screen",
            "current_streak": moodStore.calculateStreak(),
            "total_entries": moodStore.count
        ]) { [weak self] update in
            self?.handleTriggerUpdate(update)
        }
    }

    // MARK: - Nuxie Flow Handling

    /// Handles the result of a tracked event that may trigger a flow
    private func handleTriggerUpdate(_ update: TriggerUpdate) {
        switch update {
        case .entitlement(let entitlement):
            switch entitlement {
            case .allowed:
                showSuccessMessage("🎉 Welcome to Pro!")
                updateProBadge()
            case .denied:
                showError("Access denied.")
            case .pending:
                break
            }
        case .decision(let decision):
            if case .noMatch = decision {
                print("[MoodLog] No flow shown - configure an experience in Nuxie dashboard for 'upgrade_tapped' event")
            }
        case .error(let error):
            showError("Unable to load: \(error.message)")
        case .journey:
            break
        }
    }

    @objc private func noteTextChanged() {
        // Enforce character limit
        if let text = noteTextField.text, text.count > Constants.maxNoteLength {
            noteTextField.text = String(text.prefix(Constants.maxNoteLength))
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - UI Updates

    private func updateMoodSelection() {
        for button in moodButtons {
            button.isSelected = (button.moodValue == selectedMood)
        }
    }

    private func updateSaveButtonState() {
        let isEnabled = selectedMood != nil

        UIView.animate(withDuration: 0.2) {
            self.saveButton.isEnabled = isEnabled
            self.saveButton.alpha = isEnabled ? 1.0 : 0.5
        }
    }

    private func showSuccessMessage(_ message: String = "✓ Mood saved!") {
        // Create success view
        let successLabel = UILabel()
        successLabel.text = message
        successLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        successLabel.textColor = .white
        successLabel.backgroundColor = .moodSuccess
        successLabel.textAlignment = .center
        successLabel.layer.cornerRadius = 8
        successLabel.clipsToBounds = true
        successLabel.alpha = 0
        successLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(successLabel)

        NSLayoutConstraint.activate([
            successLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            successLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            successLabel.widthAnchor.constraint(equalToConstant: 160),
            successLabel.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Animate in
        UIView.animate(withDuration: 0.3, animations: {
            successLabel.alpha = 1
        }, completion: { _ in
            // Animate out after delay
            UIView.animate(withDuration: 0.3, delay: 1.5, animations: {
                successLabel.alpha = 0
            }, completion: { _ in
                successLabel.removeFromSuperview()
            })
        })
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Keyboard Handling

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }

        let contentInset = UIEdgeInsets(top: 0, left: 0, bottom: keyboardFrame.height + 20, right: 0)
        scrollView.contentInset = contentInset
        scrollView.scrollIndicatorInsets = contentInset
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        scrollView.contentInset = .zero
        scrollView.scrollIndicatorInsets = .zero
    }
}

// MARK: - UITextFieldDelegate

extension TodayViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
