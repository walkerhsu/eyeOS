import AVFoundation
import ApplicationServices
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @AppStorage("onboarding.page") private var page = 0
    @StateVar private var cartesia = Keychain.get("cartesia") ?? ""
    @StateVar private var anthropic = Keychain.get("anthropic") ?? ""
    @StateVar private var perms: [String: Bool] = [:]
    @StateVar private var confirmSkip = false
    @StateVar private var actualCm = ""
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set up eyeOS").font(.title2.bold())
                Spacer()
                Text("Step \(page + 1) of 6").foregroundStyle(.secondary)
            }
            Divider()
            Group {
                switch page {
                case 0: keys
                case 1: permissions
                case 2: shortcuts
                case 3: calibration(1, "Sit about an arm's length (~60 cm) from the screen and look at the dot.")
                case 4: calibration(2, "Follow the dot with your eyes: center, then the four corners.")
                default: calibration(3, "Work normally for 60 seconds. Blink naturally.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(width: 620, height: 520)
    }

    func next() {
        store.calibration = nil
        if page >= 5 { UserDefaults.standard.set(true, forKey: "onboarded"); page = 0; done() } else { page += 1 }
    }

    var keys: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("eyeOS watches your eyes through the Mac's camera to spot strain, and an agent decides how to help. Video never leaves your Mac except the occasional frame sent to Claude when the agent reasons.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Cartesia API key (for the voice)", text: $cartesia)
            SecureField("Anthropic API key (optional; your `claude` login is used otherwise)", text: $anthropic)
            Text(store.status.bool("has_claude") ? "✓ Claude Code login found" : "✗ `claude` CLI not found; install Claude Code or add an API key")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Save and continue") {
                    Keychain.set("cartesia", cartesia)
                    Keychain.set("anthropic", anthropic)
                    store.sidecar.restart()
                    next()
                }.keyboardShortcut(.defaultAction)
            }
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            perm("Camera", "Privacy_Camera", key: "camera") { AVCaptureDevice.requestAccess(for: .video) { _ in } }
            perm("Screen Recording (screenshots, screen brightness)", "Privacy_ScreenCapture", key: "screen") { CGRequestScreenCaptureAccess() }
            perm("Accessibility (windows, reader mode)", "Privacy_Accessibility", key: "ax") {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            perm("Automation (dark mode, page text)", "Privacy_Automation", key: "automation") { _ = automationOK() }
            Text("Chrome page reading also needs View › Developer › Allow JavaScript from Apple Events. Safari works out of the box.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Check again") { refresh() }
                Spacer()
                Button("Continue") {
                    if perms.values.allSatisfy({ $0 }) && perms.count == 4 { next() } else { confirmSkip = true }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Some permissions are missing", isPresented: $confirmSkip) {
            Button("Continue anyway") { next() }
        } message: { Text("Tools that need the missing permissions won't work until you grant them.") }
    }

    func perm(_ title: String, _ pane: String, key: String, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: perms[key] == true ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(perms[key] == true ? .green : .red)
            Text(title)
            Spacer()
            Button("Request") { request(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() } }
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
        }
    }

    func refresh() {
        perms = ["camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                 "screen": CGPreflightScreenCaptureAccess(), "ax": AXIsProcessTrusted(), "automation": automationOK()]
    }

    func automationOK() -> Bool {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to get name of first process")?.executeAndReturnError(&err)
        return err == nil
    }

    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS has no public API for Focus or the accessibility display toggles, so eyeOS runs Shortcuts you create once.")
                .fixedSize(horizontal: false, vertical: true)
            Text("In Shortcuts › New Shortcut, add the action and name it exactly:").font(.callout.weight(.medium))
            Group {
                Text("• eyeOS Focus On / eyeOS Focus Off — “Set Focus” › Do Not Disturb › On / Off (required for set_focus_mode)")
                Text("• eyeOS Contrast On / Off — “Set Increase Contrast” (optional)")
                Text("• eyeOS Transparency On / Off, eyeOS Motion On / Off — optional")
            }.font(.callout).foregroundStyle(.secondary)
            if let s = store.shortcuts {
                Text(s.bool("focus_ok") ? "✓ Focus shortcuts found" : "✗ Focus shortcuts missing")
                Text("Found: " + ((s["names"] as? [String]) ?? []).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Check again") { store.sidecar.command("check_shortcuts") }
                Spacer()
                Button("Skip (disables Focus)") { next() }
                Button("Continue") { next() }.keyboardShortcut(.defaultAction).disabled(!(store.shortcuts?.bool("focus_ok") ?? false))
            }
        }
        .onAppear { store.sidecar.command("check_shortcuts") }
    }

    func calibration(_ step: Int, _ prompt: String) -> some View {
        let c = store.calibration?.int("step") == step ? store.calibration : nil
        let phase = c?.str("phase")
        return VStack(alignment: .leading, spacing: 14) {
            Text("Calibration \(step) of 3").font(.headline)
            Text(prompt)
            if step != 2 {
                HStack { Spacer(); Circle().fill(.teal).frame(width: 18, height: 18); Spacer() }.padding(.vertical, 30)
            }
            if step == 1 {
                TextField("Actual distance in cm (optional)", text: $actualCm).frame(width: 260)
            }
            if let c {
                ProgressView(value: c.num("progress") ?? 0)
                if phase == "failed" { Text(c.obj("result")?.str("reason") ?? "Failed").foregroundStyle(.red) }
                if phase == "done" { Text("Done ✓").foregroundStyle(.green) }
            }
            if !store.connected { Text("Waiting for the sidecar to start…").foregroundStyle(.secondary) }
            Spacer()
            HStack {
                Button("Back") { store.calibration = nil; page -= 1 }
                Spacer()
                Button(phase == "failed" ? "Retry" : "Start") {
                    var args: J = ["step": step]
                    if step == 1, let cm = Double(actualCm) { args["distance_cm"] = cm }
                    store.sidecar.command("calibrate", args)
                    if step == 2 { store.overlays.showCalibrationDots() }
                }
                .disabled(!store.connected || phase == "started" || phase == "progress")
                Button(step == 3 ? "Finish" : "Continue") { next() }.keyboardShortcut(.defaultAction).disabled(phase != "done")
            }
        }
        .onChange(of: phase) { if step == 2, phase == "done" || phase == "failed" { store.overlays.hideCalibrationDots() } }
    }
}

/// Full-screen dot for gaze calibration; position follows the sidecar's `target`.
struct CalibrationDots: View {
    @EnvironmentObject var store: Store
    var body: some View {
        GeometryReader { g in
            let t = store.calibration?.str("target") ?? "center"
            let inset: CGFloat = 40
            let pos: CGPoint = switch t {
            case "top_left": .init(x: inset, y: inset)
            case "top_right": .init(x: g.size.width - inset, y: inset)
            case "bottom_right": .init(x: g.size.width - inset, y: g.size.height - inset)
            case "bottom_left": .init(x: inset, y: g.size.height - inset)
            default: .init(x: g.size.width / 2, y: g.size.height / 2)
            }
            ZStack {
                Color.black.opacity(0.9)
                Circle().fill(.teal).frame(width: 26, height: 26).position(pos).animation(.easeInOut(duration: 0.4), value: t)
            }
        }
        .ignoresSafeArea()
    }
}
