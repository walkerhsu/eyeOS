import AppKit
import Charts
import SwiftUI

/// The menu bar popover: "how am I doing?" in two seconds from any app. Leads with the one thing to do,
/// then the evidence. In Zen it shows only the Zen line (SPEC §9.11).
struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    /// A `.window` menu bar extra stays open after a click; close it before bringing up the dashboard.
    func show(_ page: Page? = nil) {
        NSApp.keyWindow?.close()
        MainWindow.show(openWindow, page: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let f = store.fatal {
                Label("The tracking engine stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(f).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                Button("Restart") { store.sidecar.restart() }
            } else if !store.connected {
                Label("Starting sidecar…", systemImage: "hourglass").foregroundStyle(.secondary)
            } else if store.inZen {
                zenLine
            } else if store.setting("tracking.paused") {
                pausedLine
            } else {
                header
                breakRow
                vitals
                trend
                context
            }
            Divider()
            actions
            Toggle(isOn: Binding(get: { store.setting("ui.show_hud") }, set: { store.set("ui.show_hud", $0) })) {
                Label("Floating HUD over other apps", systemImage: "capsule").font(.callout)
            }
            .toggleStyle(.switch).controlSize(.mini).disabled(!store.connected)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }

    // MARK: - states

    var zenLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Zen · \(duration(store.zen.num("duration_s")))", systemImage: "moon.stars.fill")
                .font(.headline).foregroundStyle(.indigo)
            let held = store.zen.int("held_back") ?? 0
            Text("eyeOS is staying quiet" + (held > 0 ? " · \(held) nudge\(held == 1 ? "" : "s") held" : ""))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    var pausedLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tracking paused", systemImage: "pause.circle.fill").font(.headline)
            Text(store.status.num("paused_until").map { "Resumes at \(hhmm($0))" } ?? "Camera is off until you resume")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - sections

    var header: some View {
        let score = store.metrics.num("eye_score")
        return HStack(spacing: 12) {
            ScoreRing(score: score, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(scoreLabel(score)).font(.headline)
                Text(topIssue(store.metrics).text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    var breakRow: some View {
        let since = store.metrics.num("since_real_break_s") ?? 0
        let due = store.settings.num("triggers.no_break.threshold") ?? 1200
        let level = levelLow(since / 60, good: due / 60, warn: due / 30)
        return VStack(alignment: .leading, spacing: 6) {
            Label("Last real break \(duration(since)) ago", systemImage: "cup.and.saucer.fill")
                .font(.callout).foregroundStyle(level == .good ? .primary : level.color)
            ProgressView(value: min(1, since / due)).tint(level.color).controlSize(.small)
            HStack(spacing: 8) {
                Button("Break now") { store.sidecar.command("break_now") }
                if let e = topIssue(store.metrics).exercise {  // the one that fits what's going on now
                    Button { store.startExercise(e) } label: { Label("\(e.title) · \(e.seconds) s", systemImage: e.icon) }
                        .buttonStyle(.borderedProminent).tint(.teal)
                }
                Spacer()
                Menu {
                    ForEach(Exercise.all) { e in
                        Button { store.startExercise(e) } label: { Label("\(e.title) · \(e.seconds) s", systemImage: e.icon) }
                    }
                } label: { Image(systemName: "figure.mind.and.body") }
                .menuIndicator(.hidden).fixedSize().help("Guided eye exercises")
            }
            .controlSize(.small)
        }
    }

    var vitals: some View {
        let m = store.metrics
        let br = m.num("blink_rate"), perclos = m.num("perclos").map { $0 * 100 }
        let issues = m.arr0("posture_issues")
        let normal = store.baseline.num("blink_rate").map { "normal \(fmt($0, 0))" } ?? "/min"
        return Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Vital(def: .get("blink_rate"), value: br == nil && m.bool("talking") ? "Talking" : fmt(br, 1), detail: normal,
                      level: levelHigh(br, good: 12, warn: 8))
                Vital(def: .get("distance_cm"), value: fmt(m.num("distance_cm"), 0, suffix: " cm"), detail: "aim 50–70",
                      level: levelHigh(m.num("distance_cm"), good: 50, warn: 40))
            }
            GridRow {
                Vital(def: .get("posture"), value: !m.bool("posture_ready") ? "Learning" : issues.isEmpty ? "Upright" : humanize(issues[0]),
                      detail: issues.isEmpty ? "posture" : "for \(duration(m.num("posture_off_s")))",
                      level: !m.bool("posture_ready") ? .none : issues.isEmpty ? .good : (m.num("posture_off_s") ?? 0) < 60 ? .warn : .bad)
                Vital(def: .get("perclos"), value: fmt(perclos, 0, suffix: "%"), detail: "eyes closed",
                      level: levelLow(perclos, good: 8, warn: 15))
            }
        }
    }

    /// Eye score over the last 10 minutes, Zen shaded like the Live timeline.
    var trend: some View {
        let now = Date().timeIntervalSince1970
        let pts = store.series.filter { $0.ts > now - 600 }.compactMap { s in s.values["eye_score"].map { (s.ts - now, $0, s.zen) } }
        return Group {
            if pts.count > 5 {
                Chart {
                    ForEach(pts.indices, id: \.self) { i in
                        if pts[i].2 {
                            RectangleMark(xStart: .value("t", pts[i].0 - 0.5), xEnd: .value("t", pts[i].0 + 0.5))
                                .foregroundStyle(.indigo.opacity(0.18))
                        }
                        AreaMark(x: .value("t", pts[i].0), y: .value("score", pts[i].1))
                            .foregroundStyle(.linearGradient(colors: [.mint.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", pts[i].0), y: .value("score", pts[i].1)).foregroundStyle(.mint)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartXScale(domain: -600...0).chartYScale(domain: 0...100)
                .frame(height: 36)
                .overlay(alignment: .topLeading) { Text("Last 10 min").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    var context: some View {
        let v = store.status.obj("local_vision") ?? [:]
        let t = store.today
        return VStack(alignment: .leading, spacing: 4) {
            if v.bool("enabled"), v.bool("ok"), let s = v.str("situation") {
                let quiet = (v.num("interruptibility") ?? 1) < 0.35
                Label(humanize(s) + (quiet ? " · holding non-urgent nudges" : ""), systemImage: "sparkles.tv")
            }
            if let a = store.lastActed {
                Label("\(toolPhrase(a.name)) · \(hhmm(a.ts.timeIntervalSince1970))", systemImage: toolIcons[a.name] ?? "sparkles")
            }
            Label("Today: \(duration(t.num("screen_time_s"))) on screen · \(t.int("breaks") ?? 0) breaks · \(duration(t.num("zen_s"))) Zen",
                  systemImage: "calendar")
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    // MARK: - controls

    var actions: some View {
        HStack(spacing: 8) {
            ZenButton()
            Spacer()
            if store.setting("tracking.paused") {
                Button { store.sidecar.command("resume") } label: { Label("Resume", systemImage: "play.fill") }
            } else {
                Menu {
                    Button("For 15 minutes") { store.sidecar.command("pause", ["minutes": 15]) }
                    Button("For 1 hour") { store.sidecar.command("pause", ["minutes": 60]) }
                    Button("Until I resume") { store.sidecar.command("pause") }
                } label: { Label("Pause", systemImage: "pause.fill") }
                .fixedSize()
            }
        }
        .disabled(!store.connected)
    }

    var footer: some View {
        HStack(spacing: 12) {
            Button("Open Dashboard") { show() }.keyboardShortcut("0")
            Spacer()
            Menu {
                Toggle("Agent Enabled", isOn: Binding(get: { store.setting("agent.enabled") }, set: { store.set("agent.enabled", $0) }))
                Picker("Provider", selection: Binding(get: { store.provider }, set: { store.set("agent.provider", $0) })) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                    Text("OpenAI-compatible").tag("openai")
                }
                Button("Run Agent Now") { store.sidecar.command("run_agent_now") }
                    .disabled(!store.agentAvailable || store.status.bool("agent_busy") || !store.setting("agent.enabled"))
                Divider()
                Button("Recalibrate Camera…") {
                    show()
                    store.setupRequest = SetupRequest(recalibrate: true)
                }
                .disabled(!store.connected)
            } label: { Image(systemName: "brain") }
            .menuIndicator(.hidden).fixedSize().help("Agent")
            Button { show(.settings) } label: { Image(systemName: "gearshape") }.keyboardShortcut(",").help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.keyboardShortcut("q").help("Quit eyeOS")
        }
        .buttonStyle(.borderless)
    }
}

/// One small metric cell in the popover grid.
private struct Vital: View {
    let def: MetricDef
    let value: String
    let detail: String
    let level: Level

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: def.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(def.color)
                .frame(width: 24, height: 24).background(def.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle().fill(level.color).frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "15:30"
func hhmm(_ ts: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ts))
}
