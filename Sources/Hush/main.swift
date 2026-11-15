import AppKit
import SwiftUI

struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var controller = Controller.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: controller)
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        switch controller.phase {
        case .off: return "speaker.slash"
        case .quiet: return "speaker"
        case .listening: return "speaker.wave.2"
        case .ducked: return "speaker.wave.1"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Controller.shared.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Controller.shared.shutdown() }
    }
}

let args = CommandLine.arguments
if args.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run(Array(args.dropFirst())) })
} else {
    HushApp.main()
}
