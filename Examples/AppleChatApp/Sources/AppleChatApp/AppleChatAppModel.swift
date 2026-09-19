#if canImport(SwiftUI)
import AppleChatIntegration
import Foundation
import SwiftUI

struct ChatConversation: Identifiable, Equatable {
    let id: UUID
    let route: FixtureConversationRoute
    let modeLabel: String
    let providerLabel: String
    let modelLabel: String
    var title: String
    var snapshot: ConversationSnapshot
    var inputError: String?

    var routeTitle: String {
        if modeLabel == "LIVE" { return "\(providerLabel) · LIVE" }
        switch route {
        case .direct: return "Streaming"
        case .validated: return "Validated"
        }
    }

    var isLive: Bool { modeLabel == "LIVE" }
}

@MainActor
final class AppleChatAppModel: ObservableObject {
    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var launchError: String?

    private var controllers: [UUID: ConversationController] = [:]
    private var observers: [UUID: Task<Void, Never>] = [:]
    private let launchConfiguration: AppleChatLaunchConfiguration?

    var isLive: Bool { launchConfiguration?.isLive == true }

    init(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        process: [String: String] = ProcessInfo.processInfo.environment
    ) {
        do {
            let configuration = try AppleChatLaunchConfiguration.resolve(arguments: arguments, process: process)
            launchConfiguration = configuration
            launchError = nil
            let initialRoute: FixtureConversationRoute = arguments.contains("--validated") ? .validated : .direct
            createConversation(route: initialRoute)
        } catch {
            launchConfiguration = nil
            launchError = renderedLaunchConfigurationError(error)
        }
    }

    deinit {
        observers.values.forEach { $0.cancel() }
    }

    @discardableResult
    func createConversation(route: FixtureConversationRoute) -> UUID? {
        do {
            let id = UUID()
            let controller: ConversationController
            let modeLabel: String
            let providerLabel: String
            let modelLabel: String
            if let launchConfiguration, launchConfiguration.isLive {
                controller = try launchConfiguration.makeController(conversationID: id)
                modeLabel = launchConfiguration.modeLabel
                providerLabel = launchConfiguration.providerLabel
                modelLabel = launchConfiguration.modelLabel
            } else {
                controller = try makeFixtureConversationController(
                    conversationID: id,
                    route: route,
                    pacing: .visible
                )
                modeLabel = "FIXTURE"
                providerLabel = "Local fixture"
                modelLabel = route == .direct ? "streaming" : "validated"
            }
            controllers[id] = controller
            conversations.insert(.init(
                id: id,
                route: route,
                modeLabel: modeLabel,
                providerLabel: providerLabel,
                modelLabel: modelLabel,
                title: modeLabel == "LIVE"
                    ? "\(providerLabel) conversation"
                    : (route == .direct ? "Streaming conversation" : "Validated conversation"),
                snapshot: .init(conversationID: id),
                inputError: nil
            ), at: 0)
            observe(controller, conversationID: id)
            return id
        } catch {
            launchError = "The conversation could not be configured. Run preflight and verify the selected model."
            return nil
        }
    }

    func send(_ text: String, conversationID: UUID) async -> Bool {
        guard let controller = controllers[conversationID] else { return false }
        do {
            _ = try await controller.send(text)
            update(conversationID) {
                $0.inputError = nil
                if $0.snapshot.items.isEmpty {
                    $0.title = Self.title(for: text)
                }
            }
            return true
        } catch ConversationControllerError.emptyInput {
            update(conversationID) { $0.inputError = "Enter a message before sending." }
        } catch ConversationControllerError.runInProgress {
            update(conversationID) { $0.inputError = "Wait for the current run to drain before sending again." }
        } catch {
            update(conversationID) { $0.inputError = "The conversation could not start." }
        }
        return false
    }

    func stop(conversationID: UUID) async {
        await controllers[conversationID]?.stop()
    }

    func conversation(_ id: UUID?) -> ChatConversation? {
        guard let id else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    private func observe(_ controller: ConversationController, conversationID: UUID) {
        let snapshots = controller.snapshots
        observers[conversationID] = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.update(conversationID) {
                    $0.snapshot = snapshot
                    if let firstUserText = snapshot.items.compactMap({ item -> String? in
                        guard case .user(let message) = item else { return nil }
                        return message.text
                    }).first {
                        $0.title = Self.title(for: firstUserText)
                    }
                }
            }
        }
    }

    private func update(_ id: UUID, _ mutation: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutation(&conversations[index])
    }

    private static func title(for text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 34 else { return normalized }
        return String(normalized.prefix(31)) + "..."
    }
}
#endif
