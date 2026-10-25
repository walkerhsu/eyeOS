import AVFoundation
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @StateVar private var newQuiet = ""
    @StateVar private var cartesia = Keychain.get("cartesia") ?? ""
    @StateVar private var codexModel: String?
    @StateVar private var agentCustom = false   // "Custom endpoint" picked, even if its URL matches a preset
    @StateVar private var visionCustom = false
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
                habitsCard
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
            SettingRow("Floating HUD", detail: "A small pill over other apps; fades when all is fine, hides in Zen and meetings") {
                Toggle("", isOn: bool("ui.show_hud")).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Blink blur", detail: "The screen softens after \(store.settings.int("blur.start_s") ?? 8) s without a blink; "
                       + "blinking clears it. Off in calls, video and Zen") {
                Toggle("", isOn: bool("blur.enabled")).labelsHidden().toggleStyle(.switch)
            }
            if store.setting("blur.enabled") {
                SettingRow("Blur strength") {
                    Slider(value: number("blur.strength"), in: 0.2...1).frame(width: 180)
                }
            }
            SettingRow("Pause tracking", detail: "Releases the camera") {
                Toggle("", isOn: bool("tracking.paused")).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    var zenCard: some View {
        SettingsCard(title: "Zen mode", icon: "moon.stars.fill", color: .indigo,
                     subtitle: "During deep focus eyeOS keeps measuring but stays invisible: no agent, no popups, no sounds.") {
            SettingRow("Detect deep focus automatically", detail: "Eyes on screen, deep work on screen, no breaks") {
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

    /// Claude, Codex, or an endpoint preset (`custom` for any other OpenAI-compatible URL).
    var agentChoice: Binding<String> {
        Binding(get: {
            guard store.provider == "openai" else { return store.provider }
            return agentCustom ? "custom" : EndpointPreset.matching(store.settings.str("agent.openai_base_url")) ?? "custom"
        }, set: { id in
            agentCustom = id == "custom"
            guard id != "claude", id != "codex" else { return store.set("agent.provider", id) }
            store.set("agent.provider", "openai")
            if let p = EndpointPreset.all.first(where: { $0.id == id }) { store.set("agent.openai_base_url", p.url) }
        })
    }

    var habitsCard: some View {
        SettingsCard(title: "Habits", icon: "hand.raised.fill", color: .orange,
                     subtitle: "Gentle fixes for eye habits you don't notice. Quiet in Zen, calls and meetings; still counted.") {
            SettingRow("Eye rubbing and lash pulling", detail: "A soft cue when your fingers reach a closing eye, then an offer to palm instead") {
                Toggle("", isOn: bool("habits.rub_coach")).labelsHidden().toggleStyle(.switch)
            }
            if store.setting("habits.rub_coach") {
                SettingRow("Cue", detail: "Your eyes are closed when it fires, so the sound is what you notice first") {
                    Picker("", selection: Binding(get: { store.settings.str("habits.touch_cue") ?? "glow+sound" },
                                                  set: { store.set("habits.touch_cue", $0) })) {
                        Text("Glow + sound").tag("glow+sound")
                        Text("Glow").tag("glow")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
            }
            SettingRow("Leaning in", detail: "After 30 s closer than your usual distance the screen edges darken; sitting back clears them") {
                Toggle("", isOn: bool("habits.lean_lens")).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Squinting at small text", detail: "Offers bigger text; after two yeses in an app it just does it") {
                Toggle("", isOn: bool("habits.squint_zoom")).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    var agentCard: some View {
        let clis = store.status.obj("agent_clis") ?? [:]
        let path = clis.str(store.provider)
        let url = store.settings.str("agent.openai_base_url") ?? ""
        return SettingsCard(title: "Agent", icon: "brain", color: .purple,
                            subtitle: store.provider == "openai" ? (path.map { "Using \($0)" } ?? "Pick a server and a model below.") :
                                path != nil ? "Using \(store.providerName) via your CLI login" :
                                store.provider == "codex" ? "Codex CLI not found. Install it (`npm i -g @openai/codex`) and run `codex login`."
                                : "Claude CLI not found. Install Claude Code or add an API key below.") {
            SettingRow("Agent enabled") { Toggle("", isOn: bool("agent.enabled")).labelsHidden().toggleStyle(.switch) }
            SettingRow("Provider", detail: store.provider == "openai" ? "Any OpenAI-compatible server; it gets numbers and short text, never images"
                                           : path.map { "Found at \($0)" } ?? "Not installed") {
                Picker("", selection: agentChoice) {
                    Text(clis.str("claude") == nil ? "Claude (not found)" : "Claude").tag("claude")
                    Text(clis.str("codex") == nil ? "Codex (not found)" : "Codex").tag("codex")
                    Divider()
                    ForEach(EndpointPreset.all) { p in Text(p.name).tag(p.id) }
                    Text("Custom endpoint").tag("custom")
                }
                .labelsHidden().frame(width: 220)
            }
            if store.provider == "codex" {
                SettingRow("Model", detail: "Leave empty to use Codex's default model") {
                    TextField("Codex default", text: Binding(get: { codexModel ?? store.settings.str("agent.codex_model") ?? "" },
                                                             set: { codexModel = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit { store.set("agent.codex_model", (codexModel ?? "").trimmingCharacters(in: .whitespaces)) }
                }
                KeyField("OpenAI API key for Codex (optional; your `codex login` is used otherwise)", account: "codex")
            } else if store.provider == "openai" {
                SettingRow("Server URL", detail: "Must serve /v1/chat/completions with tool calling") {
                    URLField(key: "agent.openai_base_url")
                }
                SettingRow("Model", detail: "Needs tool calling, e.g. Qwen 3, gpt-oss, Llama 3.1+") {
                    ModelField(role: "agent", key: "agent.openai_model", urlKey: "agent.openai_base_url", placeholder: "model id")
                }
                KeyField("API key (only if the server needs one, e.g. OpenAI or OpenRouter)", account: "agent_endpoint")
                if url.contains(":11434") {
                    Text("Ollama's default context is short: start it with OLLAMA_CONTEXT_LENGTH=16384 or more, "
                         + "or the agent's input gets cut off.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                SettingRow("Model") {
                    Picker("", selection: Binding(get: { store.settings.str("agent.model") ?? "claude-sonnet-5-5" },
                                                  set: { store.set("agent.model", $0) })) {
                        Text("Sonnet 5.5").tag("claude-sonnet-5-5"); Text("Haiku 5.5").tag("claude-haiku-5-5"); Text("Opus 5.5").tag("claude-opus-5-5")
                    }
                    .labelsHidden().frame(width: 160)
                }
                KeyField("Anthropic API key (optional; your `claude` login is used otherwise)", account: "anthropic")
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

    /// Native Ollama, or an OpenAI-compatible preset (`custom` for any other URL).
    var visionChoice: Binding<String> {
        Binding(get: {
            guard store.settings.str("privacy.vision_backend") == "openai" else { return "ollama" }
            return visionCustom ? "custom" : EndpointPreset.matching(store.settings.str("privacy.vision_base_url")) ?? "custom"
        }, set: { id in
            visionCustom = id == "custom"
            guard id != "ollama" else { return store.set("privacy.vision_backend", "ollama") }
            store.set("privacy.vision_backend", "openai")
            if let p = EndpointPreset.all.first(where: { $0.id == id }) { store.set("privacy.vision_base_url", p.url) }
        })
    }

    var privacyCard: some View {
        let v = store.status.obj("local_vision") ?? [:]
        let ollama = store.settings.str("privacy.vision_backend") != "openai"
        let offMac = v["on_device"] as? Bool == false
        return SettingsCard(title: "Privacy & on-device vision", icon: "lock.shield", color: .mint,
                            subtitle: "No webcam frames or screenshots are ever sent to \(store.providerName). "
                                + (offMac ? "The vision model describes the screen, and only that short text reaches the agent."
                                          : "A local model on this Mac describes the screen, and only that short text reaches the agent.")) {
            SettingRow("Understand what I'm doing", detail: "A vision model checks the screen every 30 s; each screenshot is wiped right after") {
                Toggle("", isOn: bool("privacy.local_vision")).labelsHidden().toggleStyle(.switch)
            }
            SettingRow("Vision server", detail: ollama ? "Ollama on this Mac; started for you if needed" : "Any OpenAI-compatible server") {
                Picker("", selection: visionChoice) {
                    Text("Ollama").tag("ollama")
                    Divider()
                    ForEach(EndpointPreset.all.filter { $0.id != "ollama" }) { p in Text(p.name).tag(p.id) }
                    Text("Custom endpoint").tag("custom")
                }
                .labelsHidden().frame(width: 220)
            }
            if !ollama {
                SettingRow("Server URL", detail: "Must serve /v1/chat/completions with image input") {
                    URLField(key: "privacy.vision_base_url")
                }
            }
            SettingRow("Model", detail: ollama ? "Any vision model pulled in Ollama (e.g. gemma4, qwen2.5vl)" : "A vision-capable model on that server") {
                ModelField(role: "vision", key: "privacy.local_model", urlKey: ollama ? "privacy.vision_backend" : "privacy.vision_base_url",
                           placeholder: "gemma4")
            }
            if !ollama {
                KeyField("API key (only if the server needs one)", account: "vision_endpoint")
            }
            if offMac {
                Label("Screenshots are sent to \(v.str("host") ?? "that server") and leave this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
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
            TextField("Sidecar repo path", text: $repo).textFieldStyle(.roundedBorder)
            HStack {
                Text("Agent and vision server keys are under Agent and Privacy.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save and restart sidecar") {
                    Keychain.set("cartesia", cartesia)
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

/// Common OpenAI-compatible servers and their default base URLs.
struct EndpointPreset: Identifiable {
    let id: String
    let name: String
    let url: String

    static let all = [
        EndpointPreset(id: "lmstudio", name: "LM Studio", url: "http://127.0.0.1:1234/v1"),
        EndpointPreset(id: "ollama", name: "Ollama", url: "http://127.0.0.1:11434/v1"),
        EndpointPreset(id: "llamacpp", name: "llama.cpp / MLX", url: "http://127.0.0.1:8080/v1"),
        EndpointPreset(id: "vllm", name: "vLLM", url: "http://127.0.0.1:8000/v1"),
        EndpointPreset(id: "openai-api", name: "OpenAI", url: "https://api.openai.com/v1"),
        EndpointPreset(id: "openrouter", name: "OpenRouter", url: "https://openrouter.ai/api/v1"),
    ]

    static func matching(_ url: String?) -> String? { all.first { $0.url == url }?.id }
}

/// A base-URL setting, saved on Return.
struct URLField: View {
    @EnvironmentObject var store: Store
    let key: String
    @StateVar private var text: String?

    var body: some View {
        TextField("http://127.0.0.1:1234/v1", text: Binding(get: { text ?? store.settings.str(key) ?? "" }, set: { text = $0 }))
            .textFieldStyle(.roundedBorder).frame(width: 260)
            .onSubmit {
                let u = (text ?? "").trimmingCharacters(in: .whitespaces)
                if u.hasPrefix("http://") || u.hasPrefix("https://") { store.set(key, u) }
                text = nil
            }
            .onChange(of: store.settings.str(key)) { _, _ in text = nil }  // a preset was picked
    }
}

/// A model-id setting, typed or picked from what the server lists (`list_models`).
struct ModelField: View {
    @EnvironmentObject var store: Store
    let role: String
    let key: String
    let urlKey: String   // refetch the list when this setting changes
    let placeholder: String
    @StateVar private var text: String?

    var body: some View {
        let m = store.models[role]
        HStack(spacing: 4) {
            TextField(placeholder, text: Binding(get: { text ?? store.settings.str(key) ?? "" }, set: { text = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit { save(text ?? "") }
            Menu {
                if m == nil { Text("Loading…") }
                if let e = m?.str("error") { Text(e) } else if m != nil && m!.arr0("models").isEmpty { Text("No models found") }
                ForEach(m?.arr0("models") ?? [], id: \.self) { id in Button(id) { save(id) } }
                Divider()
                Button("Refresh") { refresh() }
            } label: { Image(systemName: "list.bullet") }
            .menuStyle(.borderlessButton).fixedSize().help("Models on this server")
        }
        .onAppear(perform: refresh)
        .onChange(of: store.settings.str(urlKey)) { _, _ in refresh() }
    }

    func save(_ id: String) {
        let v = id.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty || role == "agent" { store.set(key, v) }
        text = nil
    }

    func refresh() {
        store.models[role] = nil
        store.sidecar.command("list_models", ["role": role])
    }
}

/// An API key kept in the Keychain and handed to the sidecar at launch, so saving restarts it.
struct KeyField: View {
    @EnvironmentObject var store: Store
    let label: String
    let account: String
    @StateVar private var value: String
    @StateVar private var saved: String

    init(_ label: String, account: String) {
        self.label = label
        self.account = account
        let v = Keychain.get(account) ?? ""
        _value = StateVar(initialValue: v)
        _saved = StateVar(initialValue: v)
    }

    var body: some View {
        HStack {
            SecureField(label, text: $value).textFieldStyle(.roundedBorder)
            Button("Save") {
                Keychain.set(account, value)
                saved = value
                store.sidecar.restart()
            }
            .disabled(value == saved)
            .help("Saves the key and restarts the sidecar")
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
