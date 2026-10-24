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
        pinned.remove(rid)
        guard let p = panels.removeValue(forKey: rid) else { return }
        guard let i = banners.firstIndex(of: rid) else { return p.orderOut(nil) }
        banners.remove(at: i)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: p.frame.width + 20, dy: 0), display: true)
        }, completionHandler: { p.orderOut(nil) })
        layoutBanners()
    }

    func show(_ m: J) {
        let rid = m.str("request_id") ?? UUID().uuidString
        let p = m.obj("payload") ?? [:]
        let screen = NSScreen.main?.frame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        switch m.str("kind") ?? "" {
        case "notice":
            let text = p.str("text") ?? ""
            present(rid, AnyView(Toast(text: text)), at: .banner)
            // longer notices stay up long enough to read or expand; an expanded one stays until dismissed
            let shownFor = min(10, max(4, Double(text.count) / 15))
            DispatchQueue.main.asyncAfter(deadline: .now() + shownFor) { [weak self] in
                guard let self, !self.pinned.contains(rid) else { return }
                self.dismiss(rid)
            }
        case "blink_pulse":
            let count = p.int("count") ?? 2, intensity = p.num("intensity") ?? 0.5
            present(rid, AnyView(EdgePulse(count: count, intensity: intensity)), frame: screen, level: .screenSaver, clickThrough: true)
            store.sidecar.send(["type": "ui_response", "request_id": rid, "result": ["shown": true]])
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 1.2 + 0.3) { [weak self] in self?.dismiss(rid) }
        case "look_away_card":
            present(rid, AnyView(LookAwayCard(message: p.str("message") ?? "Look at something far away.",
                                              seconds: p.int("duration_s") ?? 20) { [weak self] by in
                self?.respond(rid, ["dismissed_by": by])
            }), at: .banner)
        case "posture_card":
            present(rid, AnyView(LookAwayCard(message: p.str("message") ?? "Sit back and roll your shoulders.",
                                              seconds: p.int("duration_s") ?? 12, title: "Your posture is drifting",
                                              icon: "figure.stand") { [weak self] by in
                self?.respond(rid, ["dismissed_by": by])
            }), at: .banner)
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
            }), at: .banner, keyable: true)
        case "approval":
            let tool = p.str("tool") ?? ""
            present(rid, AnyView(ApprovalView(payload: p) { [weak self] choice in
                if choice == "never" { self?.store.sidecar.send(["type": "set_tool_tier", "tool": tool, "tier": "blocked"]) }
                self?.respond(rid, ["approved": choice == "allow", "remember": choice != "later"])
            }), at: .banner, keyable: true)
        case "audio_panel":
            present(rid, AnyView(AudioPill(title: p.str("title") ?? "Reading aloud") { [weak self] action in
                self?.store.sidecar.command("audio_control", ["action": action])
                if action == "stop" { self?.dismiss(rid) }
            }), size: .init(width: 360, height: 56), at: .bottomCenter)
        case "zen_recap":
            present(rid, AnyView(ZenRecapCard(payload: p) { [weak self] action in
                self?.respond(rid, ["action": action])
            }), at: .banner)
        case "doctor_card":
            present(rid, AnyView(DoctorCard(message: p.str("message") ?? "") { [weak self] in
                self?.respond(rid, ["dismissed": true])
            }), size: .init(width: 460, height: 200), at: .center, keyable: true)
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

    func showWeakBaseline(_ warning: String) {
        present("weak_baseline", AnyView(WeakBaselineCard(warning: warning) { [weak self] redo in
            self?.dismiss("weak_baseline")
            if redo { self?.store.sidecar.command("calibrate", ["step": 3]) }
        }), at: .banner)
    }

    // MARK: - panel plumbing

    enum Anchor { case banner, bottomCenter, center }
    private var banners: [String] = []  // top-right stack, newest first
    private var pinned: Set<String> = []  // banners the user expanded: no auto-dismiss
    private let bannerWidth: CGFloat = 360

    /// A banner's content changed height (text expanded or collapsed): resize its panel and restack.
    private func refit(_ rid: String) {
        guard let p = panels[rid], let host = p.contentView else { return }
        let vis = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        var f = p.frame
        f.size.height = min(host.fittingSize.height, vis.height - 20)
        p.setFrame(f, display: false)
        layoutBanners()
    }

    /// Stacks banners under the menu bar like macOS notifications, animating into place.
    private func layoutBanners() {
        let vis = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        var top = vis.maxY - 10
        for rid in banners {
            guard let p = panels[rid] else { continue }
            let target = CGRect(x: vis.maxX - bannerWidth - 12, y: top - p.frame.height, width: bannerWidth, height: p.frame.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 1
            }
            top = target.minY - 8
        }
    }

    private func present(_ rid: String, _ view: AnyView, size: CGSize = .zero, at anchor: Anchor = .center, frame: CGRect? = nil,
                         level: NSWindow.Level = .floating, keyable: Bool = false, clickThrough: Bool = false) {
        let vis = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let handle = BannerHandle(
            expanded: { [weak self] on in
                if on { self?.pinned.insert(rid) }
                DispatchQueue.main.async { self?.refit(rid) }  // after SwiftUI applies the new layout
            },
            close: { [weak self] in self?.dismiss(rid) })
        let host = NSHostingView(rootView: anchor == .banner ? AnyView(view.frame(width: bannerWidth).environment(\.banner, handle)) : view)
        // banners take their content's height (capped) so long agent text can't run off screen
        let fit = CGSize(width: bannerWidth, height: min(host.fittingSize.height, 380))
        let rect = frame ?? {
            switch anchor {
            case .banner: return CGRect(x: vis.maxX + 20, y: vis.maxY - 10 - fit.height, width: fit.width, height: fit.height)
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
        p.contentView = host
        panels[rid]?.orderOut(nil)
        panels[rid] = p
        if anchor == .banner {
            p.alphaValue = 0
            banners.removeAll { $0 == rid }
            banners.insert(rid, at: 0)
            for old in banners.dropFirst(4) { dismiss(old) }  // keep the stack short
            layoutBanners()
        }
        if keyable {
            p.makeKeyAndOrderFront(nil)
        } else {
            p.orderFrontRegardless()
        }
    }
}

// MARK: - overlay views

/// Notification-banner look: app icon, bold title, short body, compact controls.
private struct Card<Content: View>: View {
    var title = "eyeOS"
    var icon = "eye"
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(.teal.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                content.font(.system(size: 13))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
    }
}

/// Lets banner content reach its panel: resize when text expands, close from inside the card.
struct BannerHandle {
    var expanded: (Bool) -> Void = { _ in }
    var close: () -> Void = {}
}

private struct BannerHandleKey: EnvironmentKey { static let defaultValue = BannerHandle() }

extension EnvironmentValues {
    var banner: BannerHandle {
        get { self[BannerHandleKey.self] }
        set { self[BannerHandleKey.self] = newValue }
    }
}

/// Banner body text clipped to a few lines, with a chevron to expand it when it doesn't fit.
/// Expanding grows the banner and keeps it on screen; `dismissible` adds a Dismiss button for cards with no other controls.
struct ExpandableText: View {
    let text: String
    var lines = 3
    var dismissible = false
    @Environment(\.banner) private var banner
    @StateVar private var expanded = false
    @StateVar private var shownHeight: CGFloat = 0
    @StateVar private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).lineLimit(expanded ? nil : lines).fixedSize(horizontal: false, vertical: true)
                .background(height { if !expanded { shownHeight = $0 } })
                .background(Text(text).fixedSize(horizontal: false, vertical: true).hidden().background(height { fullHeight = $0 }))
            if expanded || fullHeight > shownHeight + 1 {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if expanded && dismissible { Button("Dismiss") { banner.close() }.controlSize(.small) }
                    Button {
                        expanded.toggle()
                        banner.expanded(expanded)
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.2), value: expanded)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(expanded ? "Show less" : "Show more")
                    .accessibilityLabel(expanded ? "Show less" : "Show more")
                }
            }
        }
    }

    private func height(_ set: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { g in
            Color.clear.onAppear { set(g.size.height) }.onChange(of: g.size.height) { _, h in set(h) }
        }
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Card { ExpandableText(text: text, lines: 2, dismissible: true) }
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

/// The recap lines ("Rubbed your eyes 2 times", "Blinking slowed 27%"), colored by how much they matter.
struct ZenHighlights: View {
    let items: [J]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, h in
                let color: Color = h.str("level") == "bad" ? .pink : h.str("level") == "warn" ? .orange : .secondary
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: h.str("icon") ?? "circle").font(.caption).foregroundStyle(color).frame(width: 16)
                    Text(h.str("text") ?? "").font(.callout).foregroundStyle(h.str("level") == "good" ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Shown once when a Zen session ends: what happened while eyeOS stayed silent, plus an optional 20 s rest.
struct ZenRecapCard: View {
    let payload: J
    let done: (String) -> Void
    @StateVar private var resting = false
    @StateVar private var left: Double = 20

    var body: some View {
        let mins = max(1, (payload.int("duration_s") ?? 0) / 60)
        Card(title: resting ? "Look at something far away" : "Nice focus · \(mins) min in Zen", icon: "moon.stars.fill") {
            if resting {
                HStack {
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: left / 20).stroke(.indigo, style: .init(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(left.rounded(.up)))").font(.caption2.monospacedDigit())
                    }.frame(width: 26, height: 26)
                    Text("Let your eyes relax.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { done("rested") }.controlSize(.small)
                }
                .task {
                    while left > 0 {
                        try? await Task.sleep(for: .milliseconds(100))
                        left = max(0, left - 0.1)
                    }
                    done("rested")
                }
            } else {
                let highlights = payload.obj("recap")?.arr("highlights") ?? []
                if !highlights.isEmpty {
                    Text("While you focused").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ZenHighlights(items: Array(highlights.prefix(6)))
                } else {
                VStack(alignment: .leading, spacing: 3) {
                    if let br = payload.num("blink_rate") {
                        let base = payload.num("baseline_blink_rate")
                        Text("Blink rate \(fmt(br, 0))/min" + (base.map { " (your normal \(fmt($0, 0)))" } ?? ""))
                    }
                    if let n = payload.int("held_back"), n > 0 { Text("\(n) nudge\(n == 1 ? "" : "s") held back so you could focus") }
                }
                .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if payload.bool("suggest_rest") {
                        Button("Later") { done("later") }.controlSize(.small)
                        Button("Rest eyes 20 s") { resting = true }.controlSize(.small).buttonStyle(.borderedProminent)
                    } else {
                        Button("OK") { done("ok") }.controlSize(.small)
                    }
                }
            }
        }
    }
}

struct LookAwayCard: View {
    let message: String
    let seconds: Int
    var title = "Time for a 20-second break"
    var icon = "window.vertical.open"
    let done: (String) -> Void
    @StateVar private var left: Double = 0
    var body: some View {
        Card(title: title, icon: icon) {
            ExpandableText(text: message).foregroundStyle(.secondary)
            HStack {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
                    Circle().trim(from: 0, to: left / Double(seconds)).stroke(.teal, style: .init(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(left.rounded(.up)))").font(.caption2.monospacedDigit())
                }.frame(width: 26, height: 26)
                Spacer()
                Button("Done") { done("user") }.controlSize(.small)
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
            ExpandableText(text: question)
            HStack(spacing: 6) {
                ForEach(options.prefix(4), id: \.self) { o in Button(o) { answer(o, text) }.lineLimit(1) }
                Spacer(minLength: 0)
                Button("Not now") { answer(nil, nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            if freeText {
                TextField("Or type…", text: $text).textFieldStyle(.roundedBorder).controlSize(.small).onSubmit { answer(nil, text) }
            }
        }
    }
}

struct ApprovalView: View {
    let payload: J
    let choose: (String) -> Void
    var body: some View {
        Card(title: payload.str("question") ?? "Allow eyeOS?", icon: toolIcons[payload.str("tool") ?? ""] ?? "eye") {
            ExpandableText(text: payload.str("effect") ?? "", lines: 2)
            if let r = payload.str("reason"), !r.isEmpty {
                ExpandableText(text: r, lines: 2).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Never") { choose("never") }
                Spacer(minLength: 0)
                Button("Not now") { choose("later") }
                Button("Allow") { choose("allow") }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
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

struct WeakBaselineCard: View {
    let warning: String
    let done: (_ redo: Bool) -> Void
    var body: some View {
        Card(title: "Calibration may not have succeeded", icon: "eye") {  // title is one line; keep it short
            Text("\(warning.trimmingCharacters(in: CharacterSet(charactersIn: "."))) — we suggest you try again. "
                 + "It only takes a minute. Just keep working; you don't need to do anything.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now") { done(false) }.controlSize(.small)
                Button("Try again") { done(true) }.controlSize(.small)
            }
        }
    }
}

struct DoctorCard: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        Card(title: "A gentle suggestion", icon: "heart.text.square") {
            Text(message).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Dismiss", action: dismiss).keyboardShortcut(.defaultAction) }
        }
    }
}
