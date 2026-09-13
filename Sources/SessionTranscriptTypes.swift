import SwiftUI
import AppKit

struct SessionTranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let role: SessionTranscriptRole
    let text: String
}

enum SessionTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case event

    var label: String {
        switch self {
        case .user:
            return String(localized: "sessionIndex.preview.role.user", defaultValue: "You")
        case .assistant:
            return String(localized: "sessionIndex.preview.role.assistant", defaultValue: "Agent")
        case .system:
            return String(localized: "sessionIndex.preview.role.system", defaultValue: "System")
        case .tool:
            return String(localized: "sessionIndex.preview.role.tool", defaultValue: "Tool")
        case .event:
            return String(localized: "sessionIndex.preview.role.event", defaultValue: "Event")
        }
    }

    var foregroundColor: Color {
        switch self {
        case .user: return .accentColor
        case .assistant: return .green
        case .system: return .secondary
        case .tool: return .orange
        case .event: return .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .user: return Color.accentColor.opacity(0.035)
        case .assistant: return Color.green.opacity(0.035)
        case .system: return Color.primary.opacity(0.025)
        case .tool: return Color.orange.opacity(0.035)
        case .event: return Color.primary.opacity(0.02)
        }
    }

    var bodyFontSize: CGFloat {
        switch self {
        case .tool, .system:
            return 11
        case .user, .assistant, .event:
            return 12
        }
    }

    var bodyFontDesign: Font.Design {
        switch self {
        case .tool, .system:
            return .monospaced
        case .user, .assistant, .event:
            return .default
        }
    }
}


/// A temporary, read-only recent-history view above the terminal's native portal.
/// The terminal stays mounted and starts in parallel underneath it.
private struct ConversationRestorePreview: View {
    let title: String
    let turns: [SessionTranscriptTurn]
    let background: NSColor
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(String(localized: "conversation.restoring", defaultValue: "Restoring conversation…"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "conversation.restore.showTerminal", defaultValue: "Show terminal"), action: reveal)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(turn.role.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(turn.text).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: 720, alignment: .leading).padding(24)
                    .frame(maxWidth: .infinity, alignment: .center)
            }.defaultScrollAnchor(.bottom)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: background))
    }
}

extension TerminalPanel {
    func dismissRestorePreview() {
        restorePreviewTask?.cancel()
        restorePreviewTask = nil
        restorePreviewHost?.removeFromSuperview()
        restorePreviewHost = nil
    }

    func showRestorePreview(entry: SessionEntry) {
        dismissRestorePreview()
        let background = NSColor.windowBackgroundColor
        let reveal: () -> Void = { [weak self] in self?.dismissRestorePreview() }
        let host = NSHostingView(rootView: ConversationRestorePreview(
            title: entry.title, turns: [], background: background, reveal: reveal))
        host.frame = hostedView.bounds
        host.autoresizingMask = [.width, .height]
        hostedView.addSubview(host, positioned: .above, relativeTo: nil)
        restorePreviewHost = host
        restorePreviewTask = Task { @MainActor [weak self, weak host] in
            let turns = await SessionTranscriptLoader.loadRecent(entry: entry)
            guard !Task.isCancelled, let host, host.superview != nil else { return }
            host.rootView = ConversationRestorePreview(title: entry.title, turns: turns,
                background: background, reveal: reveal)
            // Handoff as soon as the live terminal contains recent conversation
            // content. The escape button always exposes startup details; the
            // deadline also ensures an unfamiliar provider/error cannot be hidden.
            let snippets = turns.suffix(2).map {
                String($0.text.suffix(100)).filter { !$0.isWhitespace }
            }.filter { $0.count >= 24 }
            for _ in 0..<20 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, host.superview != nil, self != nil else { return }
                let screen = self?.surface.readText(region: .viewport) ?? ""
                let compact = screen.filter { !$0.isWhitespace }
                if snippets.contains(where: compact.contains) || screen.contains("Error:") {
                    break
                }
            }
            self?.dismissRestorePreview()
        }
    }
}
