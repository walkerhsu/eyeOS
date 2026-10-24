import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @StateVar private var newQuiet = ""
    @StateVar private var cartesia = Keychain.get("cartesia") ?? ""
    @StateVar private var anthropic = Keychain.get("anthropic") ?? ""
    @StateVar private var repo = UserDefaults.standard.string(forKey: "sidecar.repo_path") ?? Sidecar.devRepo
    @StateVar private var showOnboarding = false
    @StateVar private var recalibrating = false

    private let triggerIds = ["low_blink_rate", "long_stare", "incomplete_blinks", "drowsy", "long_blinks", "sustained_squint",
                              "too_close", "eye_rub", "yawning", "dark_room_bright_screen", "no_break", "break_taken", "heartbeat"]

    func bool(_ k: String) -> Binding<Bool> { Binding(get: { store.setting(k) }, set: { store.set(k, $0) }) }
    func number(_ k: String) -> Binding<Double> {
        Binding(get: { store.settings.num(k) ?? 0 }, set: { store.set(k, $0) })
    }
    func int(_ k: String) -> Binding<Int> { Binding(get: { store.settings.int(k) ?? 0 }, set: { store.set(k, $0) }) }

    func recalibrate() {
        store.calibration = nil
        UserDefaults.standard.set(3, forKey: "onboarding.page")    // first calibration page
        recalibrating = true
        showOnboarding = true
    }

    var body: some View {
        Form {
            Section("Camera") {
                LabeledContent("Status") {
                    Text(store.status.bool("calibrated") ? "✓ Calibrated" : "Not calibrated")
                        .foregroundStyle(store.status.bool("calibrated") ? .green : .orange)
                }
                Button(action: recalibrate) {
                    Label("Recalibrate camera", systemImage: "camera.metering.center.weighted")
                        .font(.headline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.connected)
            }
            Section("General") {
                Toggle("Show camera image", isOn: bool("ui.show_camera_image"))
                Toggle("Pause tracking (releases the camera)", isOn: bool("tracking.paused"))
                Toggle("Agent enabled", isOn: bool("agent.enabled"))
                Picker("Model", selection: Binding(get: { store.settings.str("agent.model") ?? "claude-sonnet-5-5" },
                                                   set: { store.set("agent.model", $0) })) {
                    Text("Sonnet 5.5").tag("claude-sonnet-5-5"); Text("Haiku 5.5").tag("claude-haiku-5-5"); Text("Opus 5.5").tag("claude-opus-5-5")
                }
                Stepper("Heartbeat every \(store.settings.int("agent.heartbeat_s") ?? 300) s", value: int("agent.heartbeat_s"), in: 60...1800, step: 60)
                Toggle("Send webcam frame + screenshot on event runs", isOn: bool("agent.send_images"))
            }
            Section {
                ForEach(triggerIds, id: \.self) { id in
                    HStack {
                        Toggle(id, isOn: bool("triggers.\(id).enabled")).frame(width: 260, alignment: .leading)
                        TextField("threshold", value: number("triggers.\(id).threshold"), format: .number).frame(width: 80)
                        TextField("sustain s", value: number("triggers.\(id).sustain_s"), format: .number).frame(width: 80)
                        Text("threshold · sustain s").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Button("Reset to defaults") { store.sidecar.command("reset_triggers") }
            } header: { Text("Triggers") }
            Section {
                ForEach(store.tools.keys.sorted(), id: \.self) { name in
                    let t = store.tools[name] ?? [:]
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.callout.monospaced())
                            Text(t.str("description") ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(t.str("approval")?.replacingOccurrences(of: "_", with: " ") ?? "").font(.caption).foregroundStyle(.secondary)
                        Text(t.str("executor") ?? "").font(.caption2).foregroundStyle(.tertiary)
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
            } header: { Text("Tools") }
            Section("Quiet apps (UI tools suppressed; calls are always quiet)") {
                let quiet = (store.settings["quiet_apps"] as? [String]) ?? []
                ForEach(quiet, id: \.self) { q in
                    HStack { Text(q); Spacer(); Button("Remove") { store.set("quiet_apps", quiet.filter { $0 != q }) } }
                }
                HStack {
                    TextField("Bundle id or window-title text", text: $newQuiet)
                    Button("Add") { if !newQuiet.isEmpty { store.set("quiet_apps", quiet + [newQuiet]); newQuiet = "" } }
                }
            }
            Section("Memory") {
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
                LabeledContent("Baseline") {
                    Text(["ear_open", "blink_rate", "blink_duration_ms", "squint_score", "w_px_cal", "distance_cm"]
                        .map { "\($0) \(fmt(store.baseline.num($0), 2))" }.joined(separator: " · ")).font(.caption.monospaced())
                }
            }
            Section("Keys") {
                SecureField("Cartesia API key (voice)", text: $cartesia)
                SecureField("Anthropic API key (optional; otherwise your `claude` login is used)", text: $anthropic)
                TextField("Sidecar repo path", text: $repo)
                Button("Save and restart sidecar") {
                    Keychain.set("cartesia", cartesia)
                    Keychain.set("anthropic", anthropic)
                    UserDefaults.standard.set(repo, forKey: "sidecar.repo_path")
                    store.sidecar.restart()
                }
            }
            Section("Demo") {
                Toggle("Demo mode (short sustains and cooldowns)", isOn: bool("demo.enabled"))
                HStack {
                    Button("Seed history") { store.sidecar.command("seed_demo"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { store.loadDay() } }
                    Button("Wipe seeded data") { store.sidecar.command("wipe_demo"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { store.loadDay() } }
                    Button("Run agent now") { store.sidecar.command("run_agent_now") }
                    Button("Check doctor eligibility") { store.sidecar.command("doctor_eligibility") }
                }
                if let d = store.doctor {
                    Text(d.bool("eligible") ? "Eligible" : "Not eligible: \(String(describing: d["detail"] ?? ""))").font(.caption)
                }
                Button("Run onboarding again") {
                    UserDefaults.standard.set(0, forKey: "onboarding.page"); recalibrating = false; showOnboarding = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showOnboarding) { OnboardingView(recalibrating: recalibrating, done: { showOnboarding = false }) }
    }
}
