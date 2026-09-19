#if canImport(SwiftUI)
import AppleChatIntegration
import AgentCore
import AgentModels
import SwiftUI

struct AppleChatRootView: View {
    @EnvironmentObject private var model: AppleChatAppModel
    @State private var selectedConversationID: UUID?

    var body: some View {
        NavigationSplitView {
            List(model.conversations, selection: $selectedConversationID) { conversation in
                ConversationRow(conversation: conversation)
                    .tag(conversation.id)
            }
            .navigationTitle("SwiftAgent")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            .toolbar {
                ToolbarItem {
                    if model.isLive {
                        Button {
                            selectedConversationID = model.createConversation(route: .direct)
                        } label: {
                            Label("New Conversation", systemImage: "plus")
                        }
                    } else {
                        Menu {
                            Button("Streaming") {
                                selectedConversationID = model.createConversation(route: .direct)
                            }
                            Button("Validated") {
                                selectedConversationID = model.createConversation(route: .validated)
                            }
                        } label: {
                            Label("New Conversation", systemImage: "plus")
                        }
                    }
                }
            }
        } detail: {
            if let conversation = model.conversation(selectedConversationID) {
                ConversationDetail(conversationID: conversation.id)
                    .id(conversation.id)
            } else if let launchError = model.launchError {
                UnavailableProviderView(message: launchError)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Select a conversation")
                        .font(.title3.weight(.semibold))
                    Text("Choose an existing conversation or create a new one.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .task {
            if selectedConversationID == nil {
                selectedConversationID = model.conversations.first?.id
            }
        }
        .onChange(of: model.conversations.map(\.id)) { ids in
            if selectedConversationID == nil || !ids.contains(selectedConversationID!) {
                selectedConversationID = ids.first
            }
        }
    }
}

private struct UnavailableProviderView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Provider unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationRow: View {
    let conversation: ChatConversation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.route == .direct ? "waveform" : "checkmark.shield")
                .foregroundStyle(conversation.isLive ? .orange : (conversation.route == .direct ? .blue : .green))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .lineLimit(2)
                Text(conversation.routeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            PhaseIndicator(phase: conversation.snapshot.phase)
        }
        .padding(.vertical, 3)
    }
}

private struct ConversationDetail: View {
    @EnvironmentObject private var model: AppleChatAppModel
    let conversationID: UUID
    @State private var input = ""

    private var conversation: ChatConversation? { model.conversation(conversationID) }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                ConversationHeader(conversation: conversation)
                Divider()
                TranscriptView(snapshot: conversation.snapshot)
                Divider()
                Composer(
                    input: $input,
                    conversation: conversation,
                    send: send,
                    stop: { Task { await model.stop(conversationID: conversationID) } }
                )
            }
            .navigationTitle(conversation.title)
        }
    }

    private func send() {
        let submitted = input
        Task {
            if await model.send(submitted, conversationID: conversationID) {
                input = ""
            }
        }
    }
}

private struct ConversationHeader: View {
    let conversation: ChatConversation

    var body: some View {
        HStack(spacing: 12) {
            Label(
                conversation.routeTitle,
                systemImage: conversation.route == .direct ? "waveform" : "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))

            Text(conversation.route == .direct
                 ? "\(conversation.modelLabel) · Incremental output"
                 : "\(conversation.modelLabel) · Published after route validation")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            PhaseLabel(phase: conversation.snapshot.phase)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct TranscriptView: View {
    let snapshot: ConversationSnapshot

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if snapshot.items.isEmpty {
                        EmptyConversationView()
                    }
                    ForEach(snapshot.items) { item in
                        TranscriptItemView(item: item)
                            .id(item.id)
                    }
                    if let terminal = snapshot.terminal {
                        TerminalBanner(terminal: terminal)
                            .id("terminal-\(snapshot.generation)")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: snapshot) { _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct EmptyConversationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Start a conversation")
                .font(.title3.weight(.semibold))
            Text("Ask to look up account A-100, or use account missing to see a recoverable tool error.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 32)
    }
}

private struct TranscriptItemView: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case .user(let message):
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
        case .assistant(let turn):
            AssistantTurnView(turn: turn)
        case .tool(let call):
            ToolCallView(call: call)
        }
    }
}

private struct AssistantTurnView: View {
    let turn: DisplayAssistantTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Assistant", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !turn.reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                    Text(turn.reasoning)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            Text(displayText)
                .foregroundStyle(turn.text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if turn.usage.inputTokens != nil || turn.usage.outputTokens != nil {
                Text(usageText(turn.usage))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageText(_ usage: ModelUsage) -> String {
        let input = usage.inputTokens.map(String.init) ?? "-"
        let output = usage.outputTokens.map(String.init) ?? "-"
        return "Input \(input) · Output \(output) tokens"
    }

    private var displayText: String {
        guard turn.text.isEmpty else { return turn.text }
        if turn.usage.inputTokens != nil || turn.usage.outputTokens != nil {
            return "Tool request completed"
        }
        return "Waiting for output..."
    }
}

private struct ToolCallView: View {
    let call: DisplayToolCall

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name.isEmpty ? "Tool call" : call.name)
                    .font(.subheadline.weight(.medium))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if call.receiptValidated {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .help("Receipt validated")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        if call.isError || call.state == .failed { return "exclamationmark.triangle.fill" }
        switch call.state {
        case .proposed: return "ellipsis.circle"
        case .admitted: return "gearshape.2"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        call.isError || call.state == .failed ? .orange : .blue
    }

    private var status: String {
        if call.isError { return "Completed with a recoverable error" }
        switch call.state {
        case .proposed: return "Proposed"
        case .admitted: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

private struct Composer: View {
    @Binding var input: String
    let conversation: ChatConversation
    let send: () -> Void
    let stop: () -> Void

    private var isBusy: Bool { conversation.snapshot.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = conversation.inputError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !isBusy { send() }
                    }

                if isBusy {
                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("Request cancellation and wait for the run to drain")
                } else {
                    Button(action: send) {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .background(.bar)
    }
}

private struct PhaseIndicator: View {
    let phase: ConversationPhase

    var body: some View {
        Circle()
            .fill(phase == .idle ? Color.secondary.opacity(0.45) : Color.accentColor)
            .frame(width: 7, height: 7)
            .accessibilityLabel(phaseLabel)
    }

    private var phaseLabel: String { PhaseLabel.title(for: phase) }
}

private struct PhaseLabel: View {
    let phase: ConversationPhase

    var body: some View {
        HStack(spacing: 6) {
            if phase != .idle { ProgressView().controlSize(.small) }
            Text(Self.title(for: phase))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func title(for phase: ConversationPhase) -> String {
        switch phase {
        case .idle: "Ready"
        case .starting: "Starting"
        case .running: "Running"
        case .stopRequested: "Stopping"
        case .draining: "Draining"
        }
    }
}

private struct TerminalBanner: View {
    let terminal: ConversationTerminal

    var body: some View {
        Label(title, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(.vertical, 4)
    }

    private var title: String {
        switch terminal {
        case .completed: "Run completed"
        case .refused: "The model refused this request"
        case .incomplete: "The response ended before completion"
        case .failed: "The run failed; provisional output was not committed"
        case .cancelled: "Run cancelled"
        }
    }

    private var icon: String {
        switch terminal {
        case .completed: "checkmark.circle.fill"
        case .refused: "hand.raised.fill"
        case .incomplete: "clock.badge.exclamationmark"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch terminal {
        case .completed: .green
        case .refused, .incomplete: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
#endif
