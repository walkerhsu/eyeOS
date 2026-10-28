import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

// What a new user needs beyond the camera, as a few cards with one clear next step each: the AI coach, screen
// awareness (the on-device vision model) and permissions. First-run setup shows them on two pages; Settings › Setup
// shows them together. Everything rechecks when eyeOS comes back to the front (after signing in in Terminal,
// installing Ollama or flipping a switch in System Settings).

/// Settings › Setup: every card in one column.
struct SetupChecklist: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentSetupCard()
            VisionSetupCard()
            PermissionsPanel(showNotes: true)
            VoiceSetupCard()
        }
        .setupChecks()
    }
}

extension View {
    /// Keeps the setup state fresh while these cards are on screen.
    func setupChecks() -> some View { modifier(SetupChecks()) }
}

private struct SetupChecks: ViewModifier {
    @EnvironmentObject var store: Store

    func body(content: Content) -> some View {
        content
            .onAppear { store.sidecar.command("setup_check"); store.refreshPermissions() }
            .onChange(of: store.connected) { _, ok in if ok { store.sidecar.command("setup_check") } }
            .onChange(of: store.provider) { _, _ in store.agentTest = nil; store.sidecar.command("setup_check") }
            .onChange(of: store.settings.str("privacy.vision_backend")) { _, _ in store.sidecar.command("setup_check") }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.sidecar.command("setup_check")
            }
    }
}

// MARK: - building blocks

enum SetupStatus { case ready, todo, optional, checking, off }

struct StatusBadge: View {
    let status: SetupStatus
    var body: some View {
        switch status {
        case .ready: Pill(text: "Ready", icon: "checkmark.circle.fill", color: .mint)
        case .todo: Pill(text: "To do", icon: "arrow.right.circle.fill", color: .orange)
        case .optional: Pill(text: "Optional", color: .secondary)
        case .checking: Pill(text: "Checking", color: .secondary, spinning: true)
        case .off: Pill(text: "Off", icon: "moon.zzz.fill", color: .secondary)
        }
    }
}

struct IconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: icon).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(color)
            .frame(width: size, height: size).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.26))
    }
}

/// An icon, a title with a short line under it, a status badge, and the next step underneath.
struct SetupCard<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let status: SetupStatus
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(icon: icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: status)
            }
            content.padding(.leading, 52)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One numbered step: a number that turns into a check, a label, and its action while it's not done.
struct SetupStep<Action: View>: View {
    let n: Int
    let title: String
    let done: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.mint : Color.white.opacity(0.12)).frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                } else {
                    Text("\(n)").font(.caption.weight(.bold))
                }
            }
            Text(title).foregroundStyle(done ? .secondary : .primary)
            Spacer()
            if !done { action }
        }
    }
}

// MARK: - AI coach

struct AgentSetupCard: View {
    @EnvironmentObject var store: Store
    @StateVar private var showKey = false

    private let providers = [("claude", "Claude", "sparkles"), ("codex", "Codex", "chevron.left.forwardslash.chevron.right"),
                             ("openai", "Other", "server.rack")]

    var body: some View {
        let a = store.setup?.obj("agent")
        let checking = a == nil || a?.str("provider") != store.provider
        let ok = !checking && a?.bool("ok") == true
        SetupCard(icon: "brain", color: .purple, title: "AI coach", subtitle: "Picks the right fix for you",
                  status: checking ? .checking : ok ? .ready : .todo) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(providers, id: \.0) { id, name, icon in chip(id, name, icon) }
                }
                if !checking { next(a, ok: ok) }
            }
        }
    }

    func chip(_ id: String, _ name: String, _ icon: String) -> some View {
        let on = store.provider == id
        return Button { store.set("agent.provider", id) } label: {
            Label(name, systemImage: icon).font(.callout.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.purple.opacity(0.3) : Color.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.purple : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func next(_ a: J?, ok: Bool) -> some View {
        let cli = store.status.obj("agent_clis")?.str(store.provider)
        if ok {
            HStack(spacing: 10) {
                Label(a?.str("detail") ?? "Connected", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                testButton
            }
        } else if store.provider == "claude" {
            HStack(spacing: 10) {
                if let cli {
                    Button { Terminal.run(shellQuote(cli) + " auth login", name: "Sign in to Claude") } label: {
                        Label("Sign in with Claude", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(showKey ? "Cancel" : "Use an API key") { showKey.toggle() }.buttonStyle(.borderless)
            }
            if showKey {
                KeyField("Anthropic API key", account: "anthropic")
            } else {
                hint("terminal", "Opens Terminal to sign in, then come back here")
            }
        } else if store.provider == "codex" {
            if let cli {
                Button { Terminal.run(shellQuote(cli) + " login", name: "Sign in to Codex") } label: {
                    Label("Sign in to Codex", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                hint("terminal", "Opens Terminal to sign in, then come back here")
            } else {
                Button { NSWorkspace.shared.open(URL(string: "https://github.com/openai/codex")!) } label: {
                    Label("Install Codex", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                hint("terminal", "brew install codex, then come back here")
            }
        } else {
            Button { store.page = .settings } label: { Label("Choose a server in Settings", systemImage: "gearshape") }
            hint("server.rack", "LM Studio, Ollama, OpenRouter or any OpenAI-compatible server")
        }
    }

    func hint(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder var testButton: some View {
        let t = store.agentTest
        if t?.bool("running") == true {
            Pill(text: "Testing", color: .secondary, spinning: true)
        } else if let t, t.bool("ok") {
            Pill(text: "Works · \(fmt(t.num("latency_s"), 1)) s", icon: "bolt.fill", color: .mint)
        } else {
            if let e = t?.str("error") {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
            }
            Button { store.agentTest = ["running": true]; store.sidecar.command("test_agent") } label: {
                Label("Test", systemImage: "bolt.fill")
            }
        }
    }
}

// MARK: - Screen awareness

struct VisionSetupCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let on = store.setting("privacy.local_vision")
        let v = store.setup?.obj("vision")
        let ollama = store.settings.str("privacy.vision_backend") != "openai"
        let ready = v?.bool("running") == true && v?.bool("has_model") == true
        let pulling = store.modelPull != nil && store.modelPull?.str("error") == nil
        SetupCard(icon: "eye.square", color: .teal, title: "Screen awareness", subtitle: "Knows when you're focused · stays on this Mac",
                  status: !on ? .off : v == nil || pulling ? .checking : ready ? .ready : .optional) {
            if !on {
                Button { store.set("privacy.local_vision", true); store.sidecar.command("setup_check") } label: {
                    Label("Turn on", systemImage: "power")
                }
            } else if !ollama {
                HStack {
                    Label(ready ? "Using your vision server" : "Your vision server isn't reachable",
                          systemImage: ready ? "checkmark" : "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Settings") { store.page = .settings }
                }
            } else if let v, !ready || pulling {
                VStack(alignment: .leading, spacing: 10) {
                    SetupStep(n: 1, title: "Install Ollama", done: v.bool("installed")) {
                        Button { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) } label: {
                            Label("Get Ollama", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    SetupStep(n: 2, title: "Download \(model)", done: v.bool("has_model") && !pulling) {
                        if pulling { progress } else {
                            Button { store.modelPull = [:]; store.sidecar.command("pull_model") } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent).disabled(!v.bool("running"))
                        }
                    }
                    if let e = store.modelPull?.str("error") {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                    Button("Skip for now") { store.set("privacy.local_vision", false) }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
            } else if ready {
                Label("\(model) runs in Ollama on this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var model: String { store.settings.str("privacy.local_model") ?? "gemma4" }

    var progress: some View {
        let p = store.modelPull ?? [:]
        let total = p.num("total") ?? 0, done = p.num("completed") ?? 0
        return HStack(spacing: 8) {
            ProgressView(value: total > 0 ? done / total : nil).frame(width: 120)
            Text(total > 0 ? "\(Int(done / total * 100))% of \(gb(total))" : "Starting…").font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    func gb(_ bytes: Double) -> String { String(format: bytes >= 1e9 ? "%.1f GB" : "%.0f MB", bytes >= 1e9 ? bytes / 1e9 : bytes / 1e6) }
}

// MARK: - Voice

struct VoiceSetupCard: View {
    var body: some View {
        SetupCard(icon: "waveform", color: .pink, title: "Natural voice", subtitle: "Uses the macOS voice until you add a Cartesia key",
                  status: Keychain.get("cartesia").map { $0.isEmpty ? .optional : .ready } ?? .optional) {
            KeyField("Cartesia API key (play.cartesia.ai)", account: "cartesia")
        }
    }
}

// MARK: - Permissions

/// Each permission with what it's for and a Grant button. Nothing here asks macOS on its own: the status is read
/// with checks that never prompt (Store.refreshPermissions), and a prompt only appears after a click on Grant.
struct PermissionsPanel: View {
    @EnvironmentObject var store: Store
    var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("camera", "video.fill", .teal, "Camera", "Tracks your eyes", required: true)
            row("screen", "rectangle.dashed.badge.record", .purple, "Screen Recording", "Sees what you're working on")
            row("ax", "accessibility", .blue, "Accessibility", "Moves windows, zooms text")
            row("automation", "gearshape.2", .orange, "Automation", "Dark mode, reads pages aloud")
            if showNotes {
                Label("Chrome reading also needs View › Developer › Allow JavaScript from Apple Events.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { store.refreshPermissions() }
    }

    func row(_ key: String, _ icon: String, _ color: Color, _ title: String, _ purpose: String, required: Bool = false) -> some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, color: color, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if required { Text("Required").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.perms[key] == true {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.mint).help("Granted")
            } else {
                Button("Grant") { Permissions.grant(key) { store.refreshPermissions() } }
            }
        }
        .padding(.vertical, 5)
    }
}

/// Permission checks that never prompt, and the prompts themselves, which only Grant buttons call.
enum Permissions {
    static let panes = ["camera": "Privacy_Camera", "screen": "Privacy_ScreenCapture", "ax": "Privacy_Accessibility",
                        "automation": "Privacy_Automation"]

    static func check(_ done: @escaping ([String: Bool]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = ["camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                     "screen": CGPreflightScreenCaptureAccess(), "ax": AXIsProcessTrusted(), "automation": automation(ask: false)]
            DispatchQueue.main.async { done(p) }
        }
    }

    /// Shows the macOS prompt where there is one, and opens the System Settings pane where the switch lives.
    /// Camera and Automation are granted in their prompt; Settings opens only if the prompt can't show (asked before).
    static func grant(_ key: String, then: @escaping () -> Void) {
        let settings = { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(panes[key]!)")!) }
        switch key {
        case "camera":
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async(execute: then) }
            } else { settings() }
        case "automation":
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = automation(ask: true)
                DispatchQueue.main.async { if !ok { settings() }; then() }
            }
        case "screen":
            CGRequestScreenCaptureAccess()
            settings()
        default:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            settings()
        }
    }

    /// Whether eyeOS may script System Events. With ask false this never prompts; System Events is started quietly
    /// if it isn't running, since its permission can't be read otherwise.
    static func automation(ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        var s = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        if s == OSStatus(procNotFound) {
            let started = DispatchSemaphore(value: 0)
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"),
                                               configuration: cfg) { _, _ in started.signal() }
            _ = started.wait(timeout: .now() + 3)
            usleep(300_000)
            s = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        }
        return s == noErr
    }
}

/// Runs a command in a new Terminal window, for interactive sign-ins. A .command file opens in Terminal without
/// needing Automation permission.
enum Terminal {
    static func run(_ command: String, name: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("eyeOS")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).command")
        let script = "#!/bin/sh\ncd ~\n\(command)\necho\necho 'All set. Close this window and go back to eyeOS.'\n"
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
