import SwiftUI

// MARK: - Filter Through Command
//
// Nav-mode `!` (or the host's menu item) opens a bar like Find in Page. The
// command runs through the host's `FilterCommandRunner` with the selected
// rows as stdin lines, and `FilterThroughCommand` maps stdout back onto rows
// in one undoable transaction.

enum FilterCommandHistory {
    static let defaultsKey = "QuagmireFilterCommandHistory"
    static let limit = 20

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func record(_ command: String, in defaults: UserDefaults = .standard) {
        var history = load(defaults).filter { $0 != command }
        history.insert(command, at: 0)
        defaults.set(Array(history.prefix(limit)), forKey: defaultsKey)
    }
}

extension EditorView {
    var canFilterThroughCommand: Bool {
        guard !readOnly, runningBlockActionID == nil,
              host.filterCommandRunner(for: document) != nil else { return false }
        let selection = state.editingBlock.map { Set([$0]) } ?? state.selection
        return !FilterThroughCommand.input(in: document, selection: selection).rows.isEmpty
    }

    func presentFilterCommand() {
        guard canFilterThroughCommand else { return }
        if let editingBlock = state.editingBlock {
            transferFocus(to: .nav(cursor: editingBlock))
        }
        findPresented = false
        filterCommandText = FilterCommandHistory.load().first ?? ""
        filterCommandPresented = true
        filterCommandFocusRequest &+= 1
    }

    func dismissFilterCommand() {
        filterCommandPresented = false
        forcePageFocusGrab()
    }

    func runFilterCommand(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !readOnly, runningBlockActionID == nil,
              let runner = host.filterCommandRunner(for: document) else { return }
        let input = FilterThroughCommand.input(in: document, selection: state.selection)
        guard !input.rows.isEmpty else { return }
        FilterCommandHistory.record(command)
        dismissFilterCommand()

        let title = "Filter Through \(command)"
        runningBlockActionID = "quagmire.filterThroughCommand"
        runningBlockActionTitle = title
        blockActionTask = Task { @MainActor in
            defer {
                runningBlockActionID = nil
                runningBlockActionTitle = nil
                blockActionTask = nil
            }
            do {
                let stdout = try await runner(command, input.stdin)
                try Task.checkCancellation()
                let output = FilterThroughCommand.lines(fromOutput: stdout)
                guard FilterThroughCommand.isCurrent(input, in: document) else {
                    throw FilterThroughCommandError.rowsChanged
                }
                var replacements: [Block] = []
                mutate(title) {
                    replacements = (try? FilterThroughCommand.apply(output: output, for: input, to: document)) ?? []
                }
                if let first = replacements.first, let last = replacements.last {
                    state.setNavSelection(blocks: Set(replacements.map(\.id)), anchor: first.id, cursor: last.id)
                }
                showActionToast(
                    replacements.isEmpty
                        ? "Removed \(input.rows.count) \(input.rows.count == 1 ? "row" : "rows")"
                        : "Filtered through \(command)"
                )
            } catch is CancellationError {
                return
            } catch {
                blockActionErrorTitle = title
                blockActionErrorMessage = error.localizedDescription
            }
        }
    }

    func filterCommandBar() -> some View {
        let count = FilterThroughCommand.input(in: document, selection: state.selection).rows.count
        return FilterCommandBar(
            command: $filterCommandText,
            rowCount: count,
            focusRequest: filterCommandFocusRequest,
            history: FilterCommandHistory.load(),
            onRun: { runFilterCommand(filterCommandText) },
            onClose: { dismissFilterCommand() }
        )
    }
}

private struct FilterCommandBar: View {
    @Binding var command: String
    let rowCount: Int
    let focusRequest: Int
    let history: [String]
    let onRun: () -> Void
    let onClose: () -> Void
    @FocusState private var isFocused: Bool
    @State private var historyIndex: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(rowCount == 1 ? "1 row |" : "\(rowCount) rows |")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            TextField("Shell command, like sort", text: $command)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .focused($isFocused)
                .onSubmit(onRun)
                #if os(macOS)
                .onExitCommand(perform: onClose)
                #endif
                .onKeyPress(.upArrow) { stepHistory(by: 1) }
                .onKeyPress(.downArrow) { stepHistory(by: -1) }
            if !history.isEmpty {
                Menu {
                    ForEach(history, id: \.self) { entry in
                        Button(entry) {
                            command = entry
                            isFocused = true
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent Commands")
            }
            Button("Run", systemImage: "return", action: onRun)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: 520)
        .onAppear {
            isFocused = true
            historyIndex = history.first == command ? 0 : nil
        }
        .onChange(of: focusRequest) { _, _ in isFocused = true }
    }

    private func stepHistory(by delta: Int) -> KeyPress.Result {
        guard !history.isEmpty else { return .ignored }
        let next = (historyIndex ?? (delta > 0 ? -1 : history.count)) + delta
        guard history.indices.contains(next) else { return .handled }
        historyIndex = next
        command = history[next]
        return .handled
    }
}
