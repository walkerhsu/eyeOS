import AVFoundation
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @StateVar private var newQuiet = ""
    @StateVar private var cartesia = Keychain.get("cartesia") ?? ""
    @StateVar private var anthropic = Keychain.get("anthropic") ?? ""
    @StateVar private var codexModel: String?
    @StateVar private var localModel: String?
    @StateVar private var confirmResetMemory = false
    @StateVar private var repo = UserDefaults.standard.string(forKey: "sidecar.repo_path") ?? Sidecar.devRepo

    private let triggerIds = ["low_blink_rate", "long_stare", "incomplete_blinks", "drowsy", "long_blinks", "sustained_squint",
                              "too_close", "eye_rub", "yawning", "dark_room_bright_screen", "no_break", "frequent_blinks",
                              "blink_decline", "posture_drift", "break_taken", "heartbeat"]

    func bool(_ k: String) -> Binding<Bool> { Binding(get: { store.setting(k) }, set: { store.set(k, $0) }) }
    func number(_ k: String) -> Binding<Double> { Binding(get: { store.settings.num(k) ?? 0 }, set: { store.set(k, $0) }) }
    /// An integer setting stored in seconds, edited in minutes.
    func minutes(_ k: String) -> Binding<Int> {
        Binding(get: { (store.settings.int(k) ?? 60) / 60 }, set: { store.set(k, $0 * 60) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 28, weight: .bold))
                cameraCard
                zenCard
                agentCard
                privacyCard
                permissionsCard
                keysCard
                quietCard
                memoryCard
                advancedCard
                demoCard
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: cards

    var cameraCard: some View {
        SettingsCard(title: "Camera & calibration", icon: "video.fill", color: .teal) {
            SettingRow("Calibration", detail: store.status.bool("calibrated") ? "Calibrated" : "Not calibrated yet") {
                Button { store.setupRequest = SetupRequest(recalibrate: true) } label: {
                    Label("Recalibrate", systemImage: "scope")
                }
                .buttonStyle(.borderedProminent).disabled(!store.connected)
            }
            Divider()
            SettingRow("Show camera on the Live page", detail: "Hide it for a cleaner score dashboard") {
                Toggle("", isOn: bool("ui.show_camera_image")).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Pause tracking", detail: "Releases the camera") {
                Toggle("", isOn: bool("tracking.paused")).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    var zenCard: some View {
        SettingsCard(title: "Zen mode", icon: "moon.stars.fill", color: .indigo,
                     subtitle: "During deep focus eyeOS keeps measuring but stays invisible: no agent, no popups, no sounds.") {
            SettingRow("Detect deep focus automatically", detail: "Eyes on screen, working in the same app, no breaks") {
                Toggle("", isOn: bool("zen.enabled")).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Enter Zen after", detail: "Shorter = goes quiet sooner") {
                Stepper("\(store.settings.int("zen.enter_min") ?? 10) min of focus",
                        value: Binding(get: { store.settings.int("zen.enter_min") ?? 10 }, set: { store.set("zen.enter_min", $0) }),
                        in: 1...60)
            }
            SettingRow("Right now", detail: store.inZen ? "In Zen for \(duration(store.zen.num("duration_s")))" : "Not in Zen") {
                Button(store.inZen ? "End Zen" : "Start Zen") { store.setZen(!store.inZen) }
            }
        }
    }

    var agentCard: some View {
        let clis = store.status.obj("agent_clis") ?? [:]
        let path = clis.str(store.provider)
        return SettingsCard(title: "Agent", icon: "brain", color: .purple,
                            subtitle: path != nil ? "Using \(store.providerName) via your CLI login" :
                                store.provider == "codex" ? "Codex CLI not found. Install it (`npm i -g @openai/codex`) and run `codex login`."
                                : "Claude CLI not found. Install Claude Code or add an API key below.") {
            SettingRow("Agent enabled") { Toggle("", isOn: bool("agent.enabled")).labelsHidden().toggleStyle(.switch) }
            SettingRow("Provider", detail: path.map { "Found at \($0)" } ?? "Not installed") {
                Picker("", selection: Binding(get: { store.provider }, set: { store.set("agent.provider", $0) })) {
                    ForEach([("claude", "Claude"), ("codex", "Codex")], id: \.0) { id, name in
                        Text(clis.str(id) == nil ? "\(name) (not found)" : name).tag(id)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            if store.provider == "codex" {
                SettingRow("Model", detail: "Leave empty to use Codex's default model") {
                    TextField("Codex default", text: Binding(get: { codexModel ?? store.settings.str("agent.codex_model") ?? "" },
                                                             set: { codexModel = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit { store.set("agent.codex_model", (codexModel ?? "").trimmingCharacters(in: .whitespaces)) }
                }
            } else {
                SettingRow("Model") {
                    Picker("", selection: Binding(get: { store.settings.str("agent.model") ?? "claude-sonnet-5-5" },
                                                  set: { store.set("agent.model", $0) })) {
                        Text("Sonnet 5.5").tag("claude-sonnet-5-5"); Text("Haiku 5.5").tag("claude-haiku-5-5"); Text("Opus 5.5").tag("claude-opus-5-5")
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
            SettingRow("Try it", detail: "Runs the agent once with the current signals; results show on the Agent page") {
                Button { store.sidecar.command("run_agent_now"); store.page = .agent } label: {
                    Label("Run agent now", systemImage: "play.fill")
                }
                .disabled(path == nil || store.status.bool("agent_busy"))
            }
            Divider()
            SettingRow("Routine check-in every", detail: "A periodic look even when nothing triggered") {
                Stepper("\(minutes("agent.heartbeat_s").wrappedValue) min", value: minutes("agent.heartbeat_s"), in: 1...60)
            }
            SettingRow("At least this long between agent runs") {
                Stepper("\(minutes("agent.global_gap_s").wrappedValue) min", value: minutes("agent.global_gap_s"), in: 1...30)
            }
            SettingRow("Same signal can re-trigger after") {
                Stepper("\(minutes("agent.trigger_cooldown_s").wrappedValue) min", value: minutes("agent.trigger_cooldown_s"), in: 1...60)
            }
        }
    }

    var privacyCard: some View {
        let v = store.status.obj("local_vision") ?? [:]
        return SettingsCard(title: "Privacy & on-device vision", icon: "lock.shield", color: .mint,
                            subtitle: "No webcam frames or screenshots are ever sent to \(store.providerName). A local model on this Mac describes the screen, and only that short text reaches the agent.") {
            SettingRow("Understand what I'm doing", detail: "A local model checks the screen every 30 s; each screenshot is wiped right after") {
                Toggle("", isOn: bool("privacy.local_vision")).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Local model", detail: "Any vision model pulled in Ollama (e.g. gemma4, qwen2.5vl)") {
                TextField("gemma4", text: Binding(get: { localModel ?? store.settings.str("privacy.local_model") ?? "gemma4" },
                                                 set: { localModel = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 160)
                    .onSubmit { if let m = localModel?.trimmingCharacters(in: .whitespaces), !m.isEmpty { store.set("privacy.local_model", m) } }
            }
            SettingRow("Look every") {
                Stepper("\(store.settings.int("privacy.screen_interval_s") ?? 30) s",
                        value: Binding(get: { store.settings.int("privacy.screen_interval_s") ?? 30 },
                                       set: { store.set("privacy.screen_interval_s", $0) }), in: 20...600, step: 10)
            }
            SettingRow("Status", detail: v.bool("ok") ? "Last look \(duration(v.num("age_s"))) ago: \(v.str("activity") ?? "–")"
                                                      : (v.str("error") ?? "Waiting for the first look")) {
                Button { store.sidecar.command("describe_screen") } label: { Label("Look now", systemImage: "eye") }
                    .disabled(!store.setting("privacy.local_vision"))
            }
        }
    }

    var permissionsCard: some View {
        SettingsCard(title: "Permissions", icon: "lock.shield.fill", color: .green,
                     subtitle: "Only the camera is required. The rest unlock optional agent actions.") {
            PermissionsList()
        }
    }

    var keysCard: some View {
        SettingsCard(title: "Keys & voice", icon: "key.fill", color: .orange) {
            SecureField("Cartesia API key (voice narration)", text: $cartesia).textFieldStyle(.roundedBorder)
            SecureField("Anthropic API key (optional; your `claude` login is used otherwise)", text: $anthropic).textFieldStyle(.roundedBorder)
            TextField("Sidecar repo path", text: $repo).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Save and restart sidecar") {
                    Keychain.set("cartesia", cartesia)
                    Keychain.set("anthropic", anthropic)
                    UserDefaults.standard.set(repo, forKey: "sidecar.repo_path")
                    store.sidecar.restart()
                }
            }
            Divider()
            ShortcutsCheck()
        }
    }

    var quietCard: some View {
        SettingsCard(title: "Quiet apps", icon: "speaker.slash.fill", color: .gray, subtitle: "No popups while these are in front. Calls are always quiet.") {
            let quiet = (store.settings["quiet_apps"] as? [String]) ?? []
            ForEach(quiet, id: \.self) { q in
                HStack { Text(q); Spacer(); Button("Remove") { store.set("quiet_apps", quiet.filter { $0 != q }) }.buttonStyle(.borderless) }
            }
            HStack {
                TextField("Bundle id or window-title text", text: $newQuiet).textFieldStyle(.roundedBorder)
                Button("Add") { if !newQuiet.isEmpty { store.set("quiet_apps", quiet + [newQuiet]); newQuiet = "" } }
            }
        }
    }

    var memoryCard: some View {
        SettingsCard(title: "Memory", icon: "brain.head.profile", color: .pink, subtitle: "Rules the agent has learned about you") {
            HStack {
                Text("Reflection runs when the display turns off, and catches up after a shutdown.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.sidecar.command("reflect_now") } label: { Label("Reflect now", systemImage: "sparkles") }
                    .disabled(!store.agentAvailable)
                Button(role: .destructive) { confirmResetMemory = true } label: { Label("Reset memory…", systemImage: "arrow.counterclockwise") }
                    .confirmationDialog("Reset the agent's memory?", isPresented: $confirmResetMemory) {
                        Button("Reset memory", role: .destructive) { store.sidecar.command("reset_memory") }
                    } message: {
                        Text("Every rule is deleted and the agent learns again only from what happens from now on, "
                             + "so rules you removed before can come back. Your baseline and tool approvals are kept.")
                    }
            }
            if store.preferences.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(Array(store.preferences.enumerated()), id: \.offset) { _, p in
                HStack {
                    Text(p.str("rule") ?? "")
                    Spacer()
                    Text(p.str("source") ?? "").font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) { store.sidecar.send(["type": "delete_preference", "id": p.int("id") ?? -1]) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless)
                }
            }
            Divider()
            Text("Baseline: " + ["ear_open", "blink_rate", "blink_duration_ms", "squint_score", "distance_cm"]
                .map { "\($0) \(fmt(store.baseline.num($0), 2))" }.joined(separator: " · "))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    var advancedCard: some View {
        SettingsCard(title: "Advanced", icon: "slider.horizontal.3", color: .secondary) {
            DisclosureGroup("Triggers") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("").frame(width: 240, alignment: .leading)
                        Text("threshold").frame(width: 80); Text("sustain s").frame(width: 80)
                    }.font(.caption2).foregroundStyle(.tertiary)
                    ForEach(triggerIds, id: \.self) { id in
                        HStack {
                            Toggle(id, isOn: bool("triggers.\(id).enabled")).frame(width: 240, alignment: .leading)
                            TextField("", value: number("triggers.\(id).threshold"), format: .number).frame(width: 80)
                            TextField("", value: number("triggers.\(id).sustain_s"), format: .number).frame(width: 80)
                        }
                    }
                    Button("Reset to defaults") { store.sidecar.command("reset_triggers") }
                }
                .padding(.top, 6)
            }
            DisclosureGroup("Tools") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.tools.keys.sorted(), id: \.self) { name in
                        let t = store.tools[name] ?? [:]
                        HStack(alignment: .top) {
                            Image(systemName: toolIcons[name] ?? "wrench.and.screwdriver").frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.callout.monospaced())
                                Text(t.str("description") ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(t.str("approval")?.replacingOccurrences(of: "_", with: " ") ?? "").font(.caption).foregroundStyle(.secondary)
                            if t.str("tier") != nil {
                                Picker("", selection: Binding(get: { t.str("tier") ?? "ask" },
                                                              set: { store.sidecar.send(["type": "set_tool_tier", "tool": name, "tier": $0]) })) {
                                    Text("auto").tag("auto"); Text("ask").tag("ask"); Text("blocked").tag("blocked")
                                }.labelsHidden().frame(width: 100)
                            } else {
                                Text(t.str("kind") ?? "").font(.caption).frame(width: 100)
                            }
                        }
                    }
                    Button("Reset approvals") { store.sidecar.command("reset_approvals") }
                }
                .padding(.top, 6)
            }
        }
    }

    var demoCard: some View {
        SettingsCard(title: "Demo", icon: "play.rectangle.fill", color: .yellow) {
            SettingRow("Demo mode", detail: "Short sustains and cooldowns") {
                Toggle("", isOn: bool("demo.enabled")).labelsHidden().toggleStyle(.switch)
            }
            HStack {
                Button("Seed history") { store.sidecar.command("seed_demo"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { store.loadDay() } }
                Button("Wipe seeded data") { store.sidecar.command("wipe_demo"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { store.loadDay() } }
                Button("Run agent now") { store.sidecar.command("run_agent_now") }
                Button("Check doctor eligibility") { store.sidecar.command("doctor_eligibility") }
            }
            if let d = store.doctor {
                Text(d.bool("eligible") ? "Eligible" : "Not eligible: \(String(describing: d["detail"] ?? ""))").font(.caption)
            }
            Button("Run setup again") { store.setupRequest = SetupRequest(recalibrate: false) }
        }
    }
}

// MARK: - building blocks

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color == .secondary ? .primary : color)
                    .frame(width: 30, height: 30).background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            control
        }
    }
}

struct PermissionsList: View {
    @StateVar private var perms: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            perm("Camera", "Required", "video.fill", "Privacy_Camera", key: "camera") { AVCaptureDevice.requestAccess(for: .video) { _ in } }
            perm("Screen Recording", "Screenshots for the agent, screen brightness", "rectangle.dashed.badge.record", "Privacy_ScreenCapture",
                 key: "screen") { CGRequestScreenCaptureAccess() }
            perm("Accessibility", "Window and reader-mode actions", "accessibility", "Privacy_Accessibility", key: "ax") {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            perm("Automation", "Dark mode, reading pages aloud", "gearshape.2", "Privacy_Automation", key: "automation") { _ = automationOK() }
            HStack {
                Text("Chrome page reading also needs View › Developer › Allow JavaScript from Apple Events.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check again", action: refresh).buttonStyle(.borderless)
            }
        }
        .onAppear(perform: refresh)
    }

    func perm(_ title: String, _ detail: String, _ icon: String, _ pane: String, key: String, request: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if perms[key] == true {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.mint).font(.callout)
            } else {
                Button("Grant") {
                    request()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
                }
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
}

/// macOS has no public API for Focus or the accessibility display toggles, so those agent tools run user-made Shortcuts.
struct ShortcutsCheck: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Shortcuts (optional)", systemImage: "square.stack.3d.up.fill").font(.callout.weight(.medium))
                Spacer()
                if let s = store.shortcuts {
                    Text(s.bool("focus_ok") ? "Focus shortcuts found" : "Focus shortcuts missing")
                        .font(.caption).foregroundStyle(s.bool("focus_ok") ? .mint : .orange)
                }
                Button("Check") { store.sidecar.command("check_shortcuts") }.buttonStyle(.borderless)
            }
            Text("For Do Not Disturb, create Shortcuts named “eyeOS Focus On” and “eyeOS Focus Off” (Set Focus › Do Not Disturb). "
                 + "Optional: “eyeOS Contrast On/Off”, “eyeOS Transparency On/Off”, “eyeOS Motion On/Off”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.sidecar.command("check_shortcuts") }
    }
}
