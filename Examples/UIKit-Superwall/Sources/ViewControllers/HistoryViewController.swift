//
//  HistoryViewController.swift
//  MoodLog
//
//  Displays mood history with feature gating for Pro users.
//  Demonstrates Nuxie SDK integration for paywall presentation and event tracking.
//

import UIKit
import Nuxie

final class HistoryViewController: UIViewController {

    // MARK: - Properties

    private let moodStore = MoodStore.shared
    private let entitlementManager = EntitlementManager.shared
    private var entries: [MoodEntry] = []

    // MARK: - UI Components

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.delegate = self
        table.dataSource = self
        table.register(HistoryCell.self, forCellReuseIdentifier: HistoryCell.reuseIdentifier)
        table.translatesAutoresizingMaskIntoConstraints = false
        return table
    }()

    private let emptyStateView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.text = "No mood entries yet.\nStart logging your mood today!"
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .moodTextSecondary
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let emptyStateEmoji: UILabel = {
        let label = UILabel()
        label.text = "📝"
        label.font = .systemFont(ofSize: 64)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setup()
        loadEntries()

        /// **Nuxie Integration: Track history_viewed event**
        /// Track when user views their history
        NuxieSDK.shared.trigger(Constants.eventHistoryViewed, properties: [
            "entry_count": entries.count,
            "is_pro": entitlementManager.isProUser,
            "timestamp": Date().timeIntervalSince1970
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadEntries()
    }

    // MARK: - Setup

    private func setup() {
        view.backgroundColor = .moodBackground
        title = "History"

        // Add table view
        view.addSubview(tableView)
        tableView.pinToSuperview()

        // Add empty state
        view.addSubview(emptyStateView)
        emptyStateView.addSubview(emptyStateEmoji)
        emptyStateView.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -64),

            emptyStateEmoji.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            emptyStateEmoji.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            emptyStateLabel.topAnchor.constraint(equalTo: emptyStateEmoji.bottomAnchor, constant: 16),
            emptyStateLabel.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            emptyStateLabel.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),
            emptyStateLabel.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor)
        ])

        // Configure toolbar
        setupToolbar()

        // Listen for data changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(moodStoreDidChange),
            name: Constants.moodStoreDidChangeNotification,
            object: nil
        )
    }

    private func setupToolbar() {
        guard entitlementManager.canAccess(.csvExport) else {
            navigationController?.setToolbarHidden(true, animated: false)
            return
        }

        // CSV export button (Pro only)
        let exportButton = UIBarButtonItem(
            title: "Export CSV",
            style: .plain,
            target: self,
            action: #selector(exportCSVTapped)
        )

        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        toolbarItems = [spacer, exportButton, spacer]
        navigationController?.setToolbarHidden(false, animated: false)
    }

    // MARK: - Data Loading

    private func loadEntries() {
        if entitlementManager.canAccess(.unlimitedHistory) {
            // Pro users: show all entries
            entries = moodStore.allEntries()
        } else {
            // Free users: show last 7 days
            entries = moodStore.entries(lastDays: Constants.freeHistoryLimit)
        }

        // Update empty state
        emptyStateView.isHidden = !entries.isEmpty
        tableView.isHidden = entries.isEmpty

        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func exportCSVTapped() {
        // Check if user has Pro access
        if entitlementManager.canAccess(.csvExport) {
            // Already has Pro - export immediately
            performCSVExport()
        } else {
            /// **Nuxie Integration: Feature gating with flows**
            /// When user tries to access Pro feature, track event and let
            /// Nuxie show upgrade flow if configured
            NuxieSDK.shared.trigger("csv_export_gated", properties: [
                "entry_count": moodStore.count,
                "source": "history_toolbar"
            ]) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.handleTriggerUpdate(update)
                }
            }
        }
    }

    /// Performs the actual CSV export
    private func performCSVExport() {
        /// **Nuxie Integration: Track successful export**
        NuxieSDK.shared.trigger(Constants.eventExportCSV, properties: [
            "entry_count": moodStore.count
        ])

        guard let csvData = moodStore.exportCSV() else {
            showError("Failed to generate CSV")
            return
        }

        // Create temporary file
        let fileName = "MoodLog-\(DateHelper.todayKey()).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try csvData.write(to: tempURL)

            // Present share sheet
            let activityVC = UIActivityViewController(
                activityItems: [tempURL],
                applicationActivities: nil
            )
            activityVC.popoverPresentationController?.barButtonItem = toolbarItems?.last

            present(activityVC, animated: true)
        } catch {
            showError("Failed to export CSV: \(error.localizedDescription)")
        }
    }

    @objc private func moodStoreDidChange() {
        loadEntries()
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// **Nuxie Integration: Track unlock event**
    /// When user wants to unlock history, track event and let Nuxie show configured flow
    private func requestHistoryUnlock() {
        NuxieSDK.shared.trigger("unlock_history_tapped", properties: [
            "visible_entries": entries.count,
            "total_entries": moodStore.count,
            "source": "history_screen"
        ]) { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handleTriggerUpdate(update)
            }
        }
    }

    // MARK: - Nuxie Flow Handling

    /// Handles the result of a tracked event that may trigger a flow
    private func handleTriggerUpdate(_ update: TriggerUpdate) {
        switch update {
        case .decision(.journeyStarted(let experience)):
            print("[MoodLog] Journey started for experience \(experience.experienceId)")
        case .decision(.experienceShown(let experience)):
            print("[MoodLog] Experience shown: \(experience.experienceId)")
        case .decision(.suppressed(let reason)):
            print("[MoodLog] Journey suppressed: \(reason)")
        case .decision(.noMatch):
            showError("No upgrade experience is configured for this event.")
        case .journey(let journey):
            print("[MoodLog] Journey \(journey.journeyId) finished: \(journey.exitReason.rawValue)")
        case .error(let error):
            showError("Unable to load: \(error.message)")
        }
    }
}

// MARK: - UITableViewDataSource

extension HistoryViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        // Add extra section for "unlock" row if not Pro and have more entries
        let needsUnlockSection = !entitlementManager.isProUser && moodStore.count > Constants.freeHistoryLimit
        return needsUnlockSection ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return entries.count
        } else {
            // "Unlock Full History" row
            return 1
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            // Regular history cell
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: HistoryCell.reuseIdentifier,
                for: indexPath
            ) as? HistoryCell else {
                return UITableViewCell()
            }

            let entry = entries[indexPath.row]
            cell.configure(with: entry)

            // Animate cell entrance
            if tableView.visibleCells.count == tableView.numberOfRows(inSection: 0) {
                cell.animateIn(delay: Double(indexPath.row) * 0.05)
            }

            return cell
        } else {
            // "Unlock Full History" cell
            let cell = UITableViewCell(style: .default, reuseIdentifier: "UnlockCell")
            cell.backgroundColor = .clear

            let unlockView = UIView()
            unlockView.backgroundColor = .moodCardBackground
            unlockView.layer.cornerRadius = Constants.cornerRadius
            unlockView.translatesAutoresizingMaskIntoConstraints = false

            let iconLabel = UILabel()
            iconLabel.text = "🔓"
            iconLabel.font = .systemFont(ofSize: 32)
            iconLabel.translatesAutoresizingMaskIntoConstraints = false

            let textStack = UIStackView()
            textStack.axis = .vertical
            textStack.spacing = 4
            textStack.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = UILabel()
            titleLabel.text = "Unlock Full History"
            titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            titleLabel.textColor = .moodTextPrimary

            let subtitleLabel = UILabel()
            subtitleLabel.text = "Go Pro to see your complete mood history"
            subtitleLabel.font = .systemFont(ofSize: 14)
            subtitleLabel.textColor = .moodTextSecondary

            let arrowLabel = UILabel()
            arrowLabel.text = "→"
            arrowLabel.font = .systemFont(ofSize: 24, weight: .medium)
            arrowLabel.textColor = .moodPrimary
            arrowLabel.translatesAutoresizingMaskIntoConstraints = false

            textStack.addArrangedSubviews([titleLabel, subtitleLabel])

            unlockView.addSubview(iconLabel)
            unlockView.addSubview(textStack)
            unlockView.addSubview(arrowLabel)

            cell.contentView.addSubview(unlockView)

            NSLayoutConstraint.activate([
                unlockView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 6),
                unlockView.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: Constants.standardPadding),
                unlockView.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -Constants.standardPadding),
                unlockView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6),
                unlockView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

                iconLabel.leadingAnchor.constraint(equalTo: unlockView.leadingAnchor, constant: 16),
                iconLabel.centerYAnchor.constraint(equalTo: unlockView.centerYAnchor),

                textStack.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 12),
                textStack.centerYAnchor.constraint(equalTo: unlockView.centerYAnchor),

                arrowLabel.trailingAnchor.constraint(equalTo: unlockView.trailingAnchor, constant: -16),
                arrowLabel.centerYAnchor.constraint(equalTo: unlockView.centerYAnchor)
            ])

            cell.selectionStyle = .none
            return cell
        }
    }
}

// MARK: - UITableViewDelegate

extension HistoryViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 1 {
            // Tapped "Unlock Full History" row
            requestHistoryUnlock()
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return indexPath.section == 0 ? 80 : 90
    }
}
