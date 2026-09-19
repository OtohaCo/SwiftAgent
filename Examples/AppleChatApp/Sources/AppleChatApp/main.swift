#if os(macOS) && canImport(SwiftUI)
import AppleChatIntegration
import AppKit
import SwiftUI

@MainActor
private final class AppleChatApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppleChatAppModel()
    private var windows: [ObjectIdentifier: NSWindow] = [:]

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { openWindow(nil) }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeValue(forKey: ObjectIdentifier(window))
    }

    @objc func openWindow(_ sender: Any?) {
        let root = AppleChatRootView().environmentObject(model)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "SwiftAgent Apple Chat"
        window.setContentSize(NSSize(width: 960, height: 680))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[ObjectIdentifier(window)] = window
        window.makeKeyAndOrderFront(nil)
    }
}

@main
@MainActor
enum SwiftAgentAppleChatApp {
    private static let delegate = AppleChatApplicationDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        app.finishLaunching()
        delegate.openWindow(nil)
        if CommandLine.arguments.contains("--second-window") {
            delegate.openWindow(nil)
        }
        app.activate(ignoringOtherApps: true)
        Task { await delegate.runLaunchDemoIfRequested() }
        app.run()
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "Quit SwiftAgent Apple Chat",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newWindow = fileMenu.addItem(
            withTitle: "New Window",
            action: #selector(AppleChatApplicationDelegate.openWindow(_:)),
            keyEquivalent: "n"
        )
        newWindow.target = delegate
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        return main
    }
}

private extension AppleChatApplicationDelegate {
    func runLaunchDemoIfRequested() async {
        let arguments = CommandLine.arguments
        guard let marker = arguments.firstIndex(of: "--demo"),
              arguments.indices.contains(marker + 1) else { return }

        let prompt = arguments[marker + 1]
        let route: FixtureConversationRoute = arguments.contains("--validated") ? .validated : .direct
        let conversationID: UUID?
        conversationID = model.conversations.first(where: { $0.route == route })?.id
            ?? model.createConversation(route: route)
        guard let conversationID else { return }
        _ = await model.send(prompt, conversationID: conversationID)
        if arguments.contains("--stop") {
            await model.stop(conversationID: conversationID)
        }
    }
}
#elseif os(iOS) && canImport(SwiftUI)
import SwiftUI

@main
struct SwiftAgentAppleChatApp: App {
    @StateObject private var model = AppleChatAppModel()

    var body: some Scene {
        WindowGroup {
            AppleChatRootView()
                .environmentObject(model)
        }
    }
}
#else
import Foundation

@main
enum SwiftAgentAppleChatApp {
    static func main() {
        print("AppleChatApp requires an Apple platform with SwiftUI.")
    }
}
#endif
