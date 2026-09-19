import Foundation
import SwiftUI

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .grok: return String(localized: "sessionIndex.agent.grok", defaultValue: "Grok")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        case .registered(let agent):
            return agent.displayName
        case .hermesAgent: return String(localized: "sessionIndex.agent.hermesAgent", defaultValue: "Hermes Agent")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String? {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .grok: return "AgentIcons/Grok"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        case .registered(let agent):
            return agent.iconAssetName
        case .hermesAgent: return "AgentIcons/HermesAgent"
        }
    }

    var systemImageName: String? {
        switch self {
        case .registered:
            return assetName == nil ? "person.crop.circle" : nil
        default:
            return nil
        }
    }
}


/// First upstream-sized extraction of the conversation-sidebar experiment.
///
/// The view intentionally reuses the native Vault index instead of the old
/// terminal-kit JSON reader. It owns only presentation/search state; live pane
/// identity and resume behavior remain with SessionEntryResumeCoordinator.
@MainActor
struct ConversationSidebarView: View {
    @ObservedObject var store: SessionIndexStore
    @ObservedObject var tabManager: TabManager

    @State private var searchText = ""
    @State private var visibleHistoryCount = 24

    private static let pageSize = 24

    private struct Row: Identifiable {
        let entry: SessionEntry
        let isOpen: Bool
        let isFocused: Bool

        var id: String { entry.id }
    }

    /// Value-only row presentation. The LazyVStack never receives the
    /// observable Vault/TabManager stores; it gets a row snapshot plus an
    /// action closure, matching the sidebar/list snapshot-boundary rule.
    private struct RowView: View {
        let row: Row
        let onActivate: @MainActor () -> Void

        var body: some View {
            Button(action: onActivate) {
                HStack(alignment: .top, spacing: 8) {
                    SessionIndexSectionIconImage(icon: .agent(row.entry.agent), size: 16)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.displayTitle(for: row.entry))
                            .font(.system(size: 12.5, weight: row.isFocused ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 5) {
                            Text(row.entry.agent.displayName)
                            if let directory = Self.directoryLabel(for: row.entry) {
                                Text("·")
                                Text(directory)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 4)
                            Text(row.entry.modified, style: .relative)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    if row.isOpen {
                        Circle()
                            .fill(row.isFocused ? Color.accentColor : Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                            .accessibilityLabel(row.isFocused ? "Focused" : "Open")
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(row.isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.isOpen ? "Focus conversation" : "Resume conversation")
            .accessibilityLabel(Self.displayTitle(for: row.entry))
        }

        private static func displayTitle(for entry: SessionEntry) -> String {
            let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.agent.displayName : trimmed
        }

        private static func directoryLabel(for entry: SessionEntry) -> String? {
            guard let cwd = entry.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cwd.isEmpty else {
                return nil
            }
            let name = URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
            return name.isEmpty ? cwd : name
        }
    }

    var body: some View {
        let rows = projectedRows()
        let openRows = rows.filter(\.isOpen)
        let historyRows = rows.filter { !$0.isOpen }
        let visibleHistoryRows = Array(historyRows.prefix(visibleHistoryCount))
        let manager = tabManager

        VStack(spacing: 0) {
            searchField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !openRows.isEmpty {
                        Text("Open")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 3)

                        ForEach(openRows) { row in
                            RowView(row: row) {
                                Self.activate(row.entry, tabManager: manager)
                            }
                        }
                    }

                    if !visibleHistoryRows.isEmpty {
                        Text("History")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 3)

                        ForEach(visibleHistoryRows) { row in
                            RowView(row: row) {
                                Self.activate(row.entry, tabManager: manager)
                            }
                        }

                        if historyRows.count > visibleHistoryRows.count {
                            Button {
                                visibleHistoryCount += Self.pageSize
                            } label: {
                                Text("Show more")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if store.isLoading && rows.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading conversations…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                    } else if rows.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No conversation history yet."
                            : "No matching conversations.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
        }
        .task {
            store.reload()
        }
        .onChange(of: searchText) { _, _ in
            visibleHistoryCount = Self.pageSize
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search conversations", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private func projectedRows() -> [Row] {
        let query = normalized(searchText)
        let terms = query.split(separator: " ").map(String.init)

        return store.entries
            .filter { entry in
                guard !terms.isEmpty else { return true }
                let haystack = normalized([
                    entry.title,
                    entry.agent.displayName,
                    entry.sessionId,
                    entry.cwd ?? ""
                ].joined(separator: " "))
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.id < rhs.id
            }
            .map { entry in
                let key = VaultLiveSessionKeys.key(for: entry)
                let target = store.liveSessionKeys.contains(key)
                    ? SessionEntryResumeCoordinator.activeTarget(for: entry, tabManager: tabManager)
                    : nil
                let focused: Bool = {
                    guard let target,
                          tabManager.selectedTabId == target.workspaceID,
                          let workspace = tabManager.tabs.first(where: { $0.id == target.workspaceID }) else {
                        return false
                    }
                    return workspace.focusedPanelId == target.surfaceID
                }()
                return Row(entry: entry, isOpen: target != nil, isFocused: focused)
            }
    }

    private static func activate(_ entry: SessionEntry, tabManager: TabManager) {
        if SessionEntryResumeCoordinator.focusIfActive(entry, tabManager: tabManager) {
            return
        }
        SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
