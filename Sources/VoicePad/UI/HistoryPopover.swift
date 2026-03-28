import AppKit

/// Shows transcript history in a popover from the menu bar icon.
final class HistoryPopover {
    static let shared = HistoryPopover()

    private var popover: NSPopover?
    private let historyStore = HistoryStore()

    private init() {}

    func show(relativeTo statusItem: NSStatusItem) {
        if popover == nil {
            let p = NSPopover()
            p.contentSize = NSSize(width: 360, height: 480)
            p.behavior = .transient
            p.contentViewController = HistoryViewController(historyStore: historyStore)
            popover = p
        }

        guard let button = statusItem.button else { return }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: - History View Controller

private final class HistoryViewController: NSViewController {
    private let historyStore: HistoryStore
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var entries: [TranscriptEntry] = []
    private var searchDebounce: Timer?

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))

        // Search field
        searchField.placeholderString = "Search transcripts..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.title = ""
        column.width = 340
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 60
        tableView.target = self
        tableView.doubleAction = #selector(copyEntry)

        // Right-click context menu
        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Copy", action: #selector(copySelectedEntry), keyEquivalent: "c")
        contextMenu.addItem(withTitle: "Edit & Learn...", action: #selector(editAndLearn), keyEquivalent: "")
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
        loadEntries()
    }

    private func loadEntries(query: String? = nil) {
        if let query, !query.isEmpty {
            entries = historyStore.search(query: query)
        } else {
            entries = historyStore.recent(limit: 10)
        }
        tableView.reloadData()
    }

    @objc private func searchChanged() {
        searchDebounce?.invalidate()
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.loadEntries(query: self?.searchField.stringValue)
        }
    }

    @objc private func copyEntry() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let text = entries[row].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copySelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        let text = entries[row].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func editAndLearn() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]

        // Show edit dialog
        let alert = NSAlert()
        alert.messageText = "Edit & Learn"
        alert.informativeText = "Edit the transcript below. Changes will be learned as vocabulary corrections."
        alert.addButton(withTitle: "Learn")
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        textView.string = entry.text
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let corrected = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard corrected != entry.text else { return }

            // Learn the diff
            let learner = CorrectionLearner()
            let result = learner.extractCorrections(original: entry.text, corrected: corrected)
            let (terms, aliases) = learner.applyToVocabulary(result)

            if terms > 0 || aliases > 0 {
                let msg = [
                    terms > 0 ? "+\(terms) terms" : nil,
                    aliases > 0 ? "+\(aliases) aliases" : nil,
                ].compactMap { $0 }.joined(separator: ", ")

                // Brief confirmation
                let confirm = NSAlert()
                confirm.messageText = "Learned: \(msg)"
                confirm.informativeText = "Corrections added to vocabulary."
                confirm.alertStyle = .informational
                confirm.addButton(withTitle: "OK")
                confirm.runModal()
            }
        }
    }
}

// MARK: - Table Delegate/DataSource

extension HistoryViewController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        let cellView = NSTableCellView()
        let text = NSTextField(wrappingLabelWithString: "")

        let timeStr = entry.timestamp.formatted(date: .omitted, time: .shortened)
        let durationStr = String(format: "%.1fs", entry.duration)
        text.attributedStringValue = formatEntry(time: timeStr, text: entry.text, duration: durationStr)
        text.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(text)

        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 4),
            text.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
            text.bottomAnchor.constraint(lessThanOrEqualTo: cellView.bottomAnchor, constant: -4),
        ])

        return cellView
    }

    private func formatEntry(time: String, text: String, duration: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        result.append(NSAttributedString(string: "\(time)  ", attributes: timeAttrs))

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        let truncated = text.count > 80 ? String(text.prefix(80)) + "..." : text
        result.append(NSAttributedString(string: truncated, attributes: textAttrs))

        let durationAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        result.append(NSAttributedString(string: "  \(duration)", attributes: durationAttrs))

        return result
    }
}
