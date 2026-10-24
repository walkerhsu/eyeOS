import AppKit
import EventKit
import SwiftUI

/// Borderless panel that can still take keyboard focus when it needs to (ask_user, approval).
final class OverlayPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
}

/// UI tools (SPEC §11.5) and Swift-executed tools (calendar, sound cue).
@MainActor
final class Overlays {
    unowned let store: Store
    private var panels: [String: OverlayPanel] = [:]
    private let events = EKEventStore()

    init(store: Store) { self.store = store }

    func respond(_ rid: String, _ result: J) {
        store.sidecar.send(["type": "ui_response", "request_id": rid, "result": result])
        dismiss(rid)
    }

    func dismiss(_ rid: String) {
        panels.removeValue(forKey: rid)?.orderOut(nil)
    }

    func show(_ m: J) {
        let rid = m.str("request_id") ?? UUID().uuidString
        let p = m.obj("payload") ?? [:]
        let screen = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        switch m.str("kind") ?? "" {
        case "notice":
            present(rid, AnyView(Toast(text: p.str("text") ?? "")), size: .init(width: 280, height: 56), at: .topRight)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.dismiss(rid) }
        case "blink_pulse":
            let count = p.int("count") ?? 2, intensity = p.num("intensity") ?? 0.5
            present(rid, AnyView(EdgePulse(count: count, intensity: intensity)), frame: screen, level: .screenSaver, clickThrough: true)
            store.sidecar.send(["type": "ui_response", "request_id": rid, "result": ["shown": true]])
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 1.2 + 0.3) { [weak self] in self?.dismiss(rid) }
        case "look_away_card":
            present(rid, AnyView(LookAwayCard(message: p.str("message") ?? "Look at something far away.",
                                              seconds: p.int("duration_s") ?? 20) { [weak self] by in
                self?.respond(rid, ["dismissed_by": by])
            }), size: .init(width: 340, height: 150), at: .bottomRight)
        case "exercise":
            present(rid, AnyView(ExerciseView(type: p.str("type") ?? "palming", steps: p.arr("steps")) { [weak self] done, elapsed in
                self?.respond(rid, ["completed": done, "elapsed_s": elapsed])
            }), frame: screen, level: .screenSaver, keyable: true)
        case "ask_user":
            present(rid, AnyView(AskView(question: p.str("question") ?? "", options: (p["options"] as? [String]) ?? [],
                                         freeText: p.bool("allow_free_text")) { [weak self] choice, text in
                var r: J = ["choice": choice as Any? ?? NSNull()]
                if let text, !text.isEmpty { r["text"] = text }
                self?.respond(rid, r)
            }), size: .init(width: 360, height: 200), at: .topRight, keyable: true)
        case "approval":
            let tool = p.str("tool") ?? ""
            present(rid, AnyView(ApprovalView(payload: p) { [weak self] choice in
                if choice == "never" { self?.store.sidecar.send(["type": "set_tool_tier", "tool": tool, "tier": "blocked"]) }
                self?.respond(rid, ["approved": choice == "allow", "remember": choice != "later"])
            }), size: .init(width: 380, height: 260), at: .topRight, keyable: true)
        case "audio_panel":
            present(rid, AnyView(AudioPill(title: p.str("title") ?? "Reading aloud") { [weak self] action in
                self?.store.sidecar.command("audio_control", ["action": action])
                if action == "stop" { self?.dismiss(rid) }
            }), size: .init(width: 360, height: 56), at: .bottomCenter)
        case "doctor_card":
            present(rid, AnyView(DoctorCard(message: p.str("message") ?? "") { [weak self] in
                self?.respond(rid, ["dismissed": true])
            }), size: .init(width: 460, height: 230), at: .center, keyable: true)
        default: break
        }
    }

    func exec(_ m: J) {
        let rid = m.str("request_id") ?? ""
        let args = m.obj("args") ?? [:]
        func reply(_ ok: Bool, _ result: Any) {
            var r: J = ["type": "tool_result", "request_id": rid, "ok": ok]
            r[ok ? "result" : "error"] = result
            store.sidecar.send(r)
        }
        switch m.str("name") {
        case "play_ambient_cue":
            let name = args.str("sound") ?? "chime"
            let fallback = ["chime": "Glass", "rain": "Submarine", "bowl": "Purr"][name] ?? "Glass"
            let sound = Bundle.main.url(forResource: name, withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: true) }
                ?? NSSound(named: fallback)
            sound?.play()
            reply(sound != nil, sound != nil ? "played \(name)" : "sound unavailable")
        case "get_calendar_events":
            let hours = Double(args.int("hours_ahead") ?? 3)
            events.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard granted else { return reply(false, "calendar access not granted") }
                    let pred = self.events.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(hours * 3600), calendars: nil)
                    let iso = ISO8601DateFormatter()
                    let rows: [J] = self.events.events(matching: pred).prefix(20).map {
                        ["title": $0.title ?? "", "start": iso.string(from: $0.startDate), "end": iso.string(from: $0.endDate),
                         "is_busy": $0.availability != .free]
                    }
                    reply(true, rows)
                }
            }
        default:
            reply(false, "unknown swift tool")
        }
    }

    func showCalibrationDots() {
        present("calibration", AnyView(CalibrationDots().environmentObject(store)), frame: NSScreen.main?.frame, level: .screenSaver)
    }

    func hideCalibrationDots() { dismiss("calibration") }

    // MARK: - panel plumbing

    enum Anchor { case topRight, bottomRight, bottomCenter, center }

    private func present(_ rid: String, _ view: AnyView, size: CGSize = .zero, at anchor: Anchor = .center, frame: CGRect? = nil,
                         level: NSWindow.Level = .floating, keyable: Bool = false, clickThrough: Bool = false) {
        let vis = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let rect = frame ?? {
            switch anchor {
            case .topRight: return CGRect(x: vis.maxX - size.width - 16, y: vis.maxY - size.height - 16, width: size.width, height: size.height)
            case .bottomRight: return CGRect(x: vis.maxX - size.width - 16, y: vis.minY + 16, width: size.width, height: size.height)
            case .bottomCenter: return CGRect(x: vis.midX - size.width / 2, y: vis.minY + 24, width: size.width, height: size.height)
            case .center: return CGRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height)
            }
        }()
        let p = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.keyable = keyable
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = frame == nil
        p.ignoresMouseEvents = clickThrough
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        panels[rid]?.orderOut(nil)
        panels[rid] = p
        if keyable {
            p.makeKeyAndOrderFront(nil)
        } else {
            p.orderFrontRegardless()
        }
    }
}

// MARK: - overlay views

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Card { Label(text, systemImage: "eye").font(.callout.weight(.medium)) }
    }
}

struct EdgePulse: View {
    let count: Int
    let intensity: Double
    @StateVar private var on = false
    var body: some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(LinearGradient(colors: [.cyan.opacity(0.9), .teal.opacity(0.4)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 40)
                .blur(radius: 30)
                .opacity(on ? 0.35 + 0.65 * intensity : 0)
                .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .task {
            for _ in 0..<count {
                withAnimation(.easeInOut(duration: 0.6)) { on = true }
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.easeInOut(duration: 0.6)) { on = false }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}

struct LookAwayCard: View {
    let message: String
    let seconds: Int
    let done: (String) -> Void
    @StateVar private var left: Double = 0
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 5)
                    Circle().trim(from: 0, to: left / Double(seconds)).stroke(.teal, style: .init(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(left.rounded(.up)))").font(.title3.monospacedDigit())
                }.frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Done") { done("user") }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .task {
            left = Double(seconds)
            while left > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                left = max(0, left - 0.1)
            }
            done("timeout")
        }
    }
}

struct ExerciseView: View {
    let type: String
    let steps: [J]
    let done: (Bool, Int) -> Void
    @StateVar private var idx = 0
    @StateVar private var left = 0
    @StateVar private var elapsed = 0
    @StateVar private var phase = false
    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 36) {
                animation.frame(width: 260, height: 260)
                Text(steps.indices.contains(idx) ? steps[idx].str("text") ?? "" : "")
                    .font(.title2).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 560)
                Text("\(left)").font(.system(size: 44, weight: .light).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                Button("Skip") { done(false, elapsed) }.buttonStyle(.bordered).tint(.white)
            }
        }
        .task {
            withAnimation(.easeInOut(duration: type == "focus_shift" ? 2.5 : 3).repeatForever()) { phase = true }
            for (i, s) in steps.enumerated() {
                idx = i
                left = s.int("seconds") ?? 5
                while left > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    left -= 1
                    elapsed += 1
                }
            }
            done(true, elapsed)
        }
    }

    @ViewBuilder var animation: some View {
        switch type {
        case "focus_shift":
            ZStack {
                Circle().fill(.teal).frame(width: phase ? 18 : 90).offset(y: phase ? -60 : 40).opacity(phase ? 0.6 : 1)
            }
        case "deliberate_blink":
            Circle().fill(.teal.opacity(0.7)).scaleEffect(phase ? 1 : 0.35)
        default:
            Image(systemName: "hands.and.sparkles.fill").resizable().scaledToFit().foregroundStyle(.teal)
                .opacity(phase ? 1 : 0.5).scaleEffect(phase ? 1 : 0.9)
        }
    }
}

struct AskView: View {
    let question: String
    let options: [String]
    let freeText: Bool
    let answer: (String?, String?) -> Void
    @StateVar private var text = ""
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("eyeOS", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                Text(question).font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack { ForEach(options, id: \.self) { o in Button(o) { answer(o, text) } } }
                if freeText {
                    TextField("Or type…", text: $text).onSubmit { answer(nil, text) }
                }
                Button("Not now") { answer(nil, nil) }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct ApprovalView: View {
    let payload: J
    let choose: (String) -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(payload.bool("first_use") ? "eyeOS wants to try something new" : "eyeOS asks",
                      systemImage: toolIcons[payload.str("tool") ?? ""] ?? "eye").font(.caption).foregroundStyle(.secondary)
                Text(payload.str("question") ?? "").font(.headline)
                Text(payload.str("effect") ?? "").font(.callout)
                if let r = payload.str("reason"), !r.isEmpty {
                    Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Never") { choose("never") }
                    Spacer()
                    Button("Not now") { choose("later") }
                    Button("Allow") { choose("allow") }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct AudioPill: View {
    let title: String
    let control: (String) -> Void
    @StateVar private var paused = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.teal)
            Text(title).lineLimit(1).font(.callout)
            Spacer()
            Button { paused.toggle(); control(paused ? "pause" : "resume") } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }.buttonStyle(.borderless)
            Button { control("stop") } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
    }
}

struct DoctorCard: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Label("A gentle suggestion", systemImage: "heart.text.square").font(.headline).foregroundStyle(.teal)
                Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Dismiss", action: dismiss).keyboardShortcut(.defaultAction) }
            }
        }
    }
}
