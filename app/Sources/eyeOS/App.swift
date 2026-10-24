import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)  // needed when launched as a bare SwiftPM executable
        MainActor.assumeIsolated {
            Store.shared.sidecar.start()
            Store.shared.hud.start()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }  // closes to the menu bar
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { MainWindow.show(nil) } }  // Dock icon click
        return true
    }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { Store.shared.sidecar.stop(wait: true) }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case live = "Live", log = "Log", agent = "Agent", settings = "Settings"
    var id: String { rawValue }
    var icon: String { ["Live": "eye", "Log": "list.bullet.rectangle", "Agent": "brain", "Settings": "gearshape"][rawValue]! }
}

/// Brings the dashboard window back from anywhere (menu bar, Dock). SwiftUI's `openWindow` alone can fail to
/// reopen a closed `Window` scene from a menu bar extra, so this falls back to hosting RootView in our own NSWindow.
@MainActor
enum MainWindow {
    private static var fallback: NSWindow?

    private static func visible() -> NSWindow? {
        NSApp.windows.first { w in
            (w === fallback || w.identifier?.rawValue.hasPrefix("main") == true) && (w.isVisible || w.isMiniaturized)
        }
    }

    static func show(_ openWindow: OpenWindowAction?, page: Page? = nil) {
        if let page { Store.shared.page = page }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = visible() {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        openWindow?(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + (openWindow == nil ? 0 : 0.35)) {
            if let w = visible() { w.makeKeyAndOrderFront(nil); return }
            let w = fallback ?? {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                w.title = "eyeOS"
                w.isReleasedWhenClosed = false
                w.contentViewController = NSHostingController(rootView: RootView().environmentObject(Store.shared)
                    .frame(minWidth: 1000, minHeight: 680))
                w.setContentSize(NSSize(width: 1240, height: 800))
                w.center()
                fallback = w
                return w
            }()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
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
            MenuBarPanel().environmentObject(store)
        } label: {
            // Zen: a plain icon, no numbers or colors that could pull attention
            if store.inZen {
                Image(systemName: "eye")
            } else {
                let score = store.metrics.num("eye_score")
                let dot = ["good": "🟢", "warn": "🟠", "bad": "🔴"][String(describing: store.worstLevel)] ?? ""
                Text("👁 \(score.map { String(Int($0.rounded())) } ?? "–") \(dot)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @StateVar private var onboarding = !UserDefaults.standard.bool(forKey: "onboarded")

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { store.page }, set: { if let p = $0 { store.page = p } })) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
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
                switch store.page {
                case .live: LiveView()
                case .log: LogView()
                case .agent: AgentBoard()
                case .settings: SettingsView()
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $onboarding) { OnboardingView(done: { onboarding = false }).environmentObject(store) }
        .sheet(item: $store.setupRequest) { r in
            OnboardingView(recalibrating: r.recalibrate, done: { store.setupRequest = nil }).environmentObject(store)
        }
    }
}
