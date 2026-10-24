import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)  // needed when launched as a bare SwiftPM executable
        MainActor.assumeIsolated { Store.shared.sidecar.start() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }  // closes to the menu bar
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { Store.shared.sidecar.stop(wait: true) }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case live = "Live", log = "Log", agent = "Agent", settings = "Settings"
    var id: String { rawValue }
    var icon: String { ["Live": "eye", "Log": "list.bullet.rectangle", "Agent": "brain", "Settings": "gearshape"][rawValue]! }
}

@main
struct EyeOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("eyeOS", id: "main") {
            RootView().environmentObject(store).frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1240, height: 800)

        MenuBarExtra {
            MenuBarMenu().environmentObject(store)
        } label: {
            let br = store.metrics.num("blink_rate")
            let dot = ["good": "🟢", "warn": "🟠", "bad": "🔴"][String(describing: store.worstLevel)] ?? ""
            Text("👁 \(br.map { String(Int($0)) } ?? "–") \(dot)")
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @StateVar private var page: Page? = .live
    @StateVar private var onboarding = !UserDefaults.standard.bool(forKey: "onboarded")

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                .navigationSplitViewColumnWidth(170)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(store.connected ? .green : .orange).frame(width: 7)
                Text(store.connected ? "sidecar connected" : "starting sidecar…").font(.caption2).foregroundStyle(.secondary)
            }.padding(10)
        } detail: {
            VStack(spacing: 0) {
                if let f = store.fatal {
                    ScrollView {
                        Text(f).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160).padding(10).background(.red.opacity(0.15))
                    .overlay(alignment: .topTrailing) { Button("Restart") { store.sidecar.restart() }.padding(8) }
                }
                if let e = store.lastError {
                    HStack { Text(e).font(.caption); Spacer(); Button("×") { store.lastError = nil }.buttonStyle(.borderless) }
                        .padding(6).background(.orange.opacity(0.15))
                }
                switch page ?? .live {
                case .live: LiveView()
                case .log: LogView()
                case .agent: AgentBoard()
                case .settings: SettingsView()
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $onboarding) { OnboardingView(done: { onboarding = false }) }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open eyeOS") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button(store.setting("tracking.paused") ? "Resume tracking" : "Pause tracking") {
            store.sidecar.command(store.setting("tracking.paused") ? "resume" : "pause")
        }
        Button("Agent: \(store.setting("agent.enabled") ? "On" : "Off")") { store.set("agent.enabled", !store.setting("agent.enabled")) }
        if let a = store.lastActed {
            Text("Last action: \(a.name) at \(clock(a.ts.timeIntervalSince1970))")
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
