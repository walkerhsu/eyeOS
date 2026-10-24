import SwiftUI

// MARK: - app bar

/// The header every main page shares: big title, live status pills, page controls, and the Zen button.
struct AppBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 28, weight: .bold))
                    if let subtitle { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
                }
                StatusPills()
            }
            Spacer(minLength: 12)
            trailing
            ZenButton()
        }
    }
}

extension AppBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct StatusPills: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            trackingPill
            calibrationPill
            agentPill
            visionPill
        }
    }

    @ViewBuilder var visionPill: some View {
        let v = store.status.obj("local_vision") ?? [:]
        if store.connected && v.bool("enabled") {
            let situation = v.str("situation").map(humanize)
            let quiet = (v.num("interruptibility") ?? 1) < 0.35
            Button { store.page = .settings } label: {
                Pill(text: v.bool("ok") ? (situation.map { "\($0)\(quiet ? " · holding nudges" : "")" } ?? "On-device vision") : "Vision off",
                     icon: v.bool("ok") ? "lock.shield.fill" : "lock.slash", color: v.bool("ok") ? (quiet ? .indigo : .mint) : .secondary)
            }
            .buttonStyle(.plain)
            .help(v.bool("ok") ? "On-device conductor: \(v.str("activity") ?? "–"). \(v.str("reason") ?? "") Screenshots are wiped after each check and never leave this Mac."
                               : (v.str("error") ?? "Starting the local model…"))
        }
    }

    @ViewBuilder var trackingPill: some View {
        let m = store.metrics
        if !store.connected {
            Pill(text: "Starting…", color: .orange, spinning: true)
        } else if store.setting("tracking.paused") {
            Pill(text: "Paused", icon: "pause.fill")
        } else if !store.status.bool("camera_ok") {
            Pill(text: "Camera off", icon: "video.slash.fill", color: .pink)
        } else if !m.bool("face_present") {
            Pill(text: "Looking for you", icon: "person.crop.circle.badge.questionmark", color: .orange)
        } else {
            Pill(text: "Tracking · \(fmt(store.status.num("fps"), 0)) fps", icon: "dot.radiowaves.left.and.right", color: .mint)
        }
    }

    @ViewBuilder var calibrationPill: some View {
        let c = store.calibration
        if c?.int("step") == 3, let phase = c?.str("phase"), phase == "started" || phase == "progress" {
            let left = Int((1 - (c?.num("progress") ?? 0)) * 60)
            Pill(text: "Learning your normal blink rate · \(left)s", color: .teal, spinning: true)
        } else if c?.int("step") == 3, c?.str("phase") == "failed" {
            Button { store.sidecar.command("calibrate", ["step": 3]) } label: {
                Pill(text: "Baseline failed · retry", icon: "arrow.clockwise", color: .orange)
            }.buttonStyle(.plain)
        } else if store.connected && !store.status.bool("calibrated") {
            Button { store.setupRequest = SetupRequest(recalibrate: true) } label: {
                Pill(text: "Not calibrated · set up", icon: "scope", color: .yellow)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder var agentPill: some View {
        if !store.connected {
            EmptyView()
        } else if !store.agentAvailable {
            Button { store.page = .settings } label: {
                Pill(text: "\(store.providerName) unavailable", icon: "exclamationmark.triangle", color: .orange)
            }
            .buttonStyle(.plain)
            .help("\(store.agentMissing). Click to choose a provider in Settings.")
        } else if !store.setting("agent.enabled") {
            Pill(text: "Agent off", icon: "brain")
        } else if store.status.bool("agent_busy") {
            Pill(text: "\(store.providerName) thinking", color: .purple, spinning: true)
        } else if store.inZen {
            Pill(text: "Agent silent", icon: "brain", color: .indigo)
        } else {
            Pill(text: "Agent watching · \(store.providerName)", icon: "brain", color: .purple)
        }
    }
}

/// A row of options with counts, styled as one rounded control (the Log page's filter).
struct CountSegmented<T: Hashable>: View {
    let options: [(value: T, label: String, icon: String, count: Int, color: Color)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = selection == o.value
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = o.value } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: o.icon).font(.caption.weight(.semibold)).foregroundStyle(on ? o.color : .secondary)
                        Text(o.label).font(.callout.weight(on ? .semibold : .regular))
                        Text("\(o.count)").font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background((on ? o.color : Color.white).opacity(on ? 0.25 : 0.08), in: Capsule())
                            .foregroundStyle(on ? o.color : .secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(on ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
    }
}

// MARK: - markdown

/// Renders the agent's markdown: headings, bullet / numbered lists, code blocks, rules, and inline styles.
struct MarkdownText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary

    enum Block {
        case para(String), heading(String, Int), item(marker: String, text: String, indent: Int), code(String), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, b in view(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder func view(_ b: Block) -> some View {
        switch b {
        case .para(let s):
            Text(Self.inline(s)).font(font).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        case .heading(let s, let level):
            Text(Self.inline(s)).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 2)
        case .item(let marker, let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker).font(font.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: .trailing)
                Text(Self.inline(s)).font(font).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14 + 2)
        case .code(let s):
            Text(s).font(.callout.monospaced()).foregroundStyle(.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = [], para: [String] = [], code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.para(para.joined(separator: " "))) }
            para = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if line.isEmpty { flush(); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 { flush(); out.append(.rule); continue }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[h] == " " {
                flush()
                out.append(.heading(String(line[h...]).trimmingCharacters(in: .whitespaces), line.distance(from: line.startIndex, to: h)))
                continue
            }
            if let r = line.range(of: #"^([-*•+])\s+"#, options: .regularExpression) {
                flush(); out.append(.item(marker: "•", text: String(line[r.upperBound...]), indent: indent)); continue
            }
            if let r = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush()
                out.append(.item(marker: line[r].trimmingCharacters(in: .whitespaces), text: String(line[r.upperBound...]), indent: indent))
                continue
            }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}

/// Splits agent text into a one-sentence headline and the rest (Decision card).
func headlineSplit(_ text: String) -> (headline: String, rest: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return ("", "") }
    if let first = MarkdownText.parse(t).first, case .heading(let h, _) = first {
        let lines = t.components(separatedBy: "\n")
        return (h, lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let firstPara = t.components(separatedBy: "\n\n")[0]
    if firstPara.contains("\n- ") || firstPara.hasPrefix("- ") || firstPara.hasPrefix("* ") { return ("", t) }
    // first sentence end: ". " / "! " / "? " followed by an uppercase letter, or the end of the first line
    var end: String.Index? = nil
    var i = t.startIndex
    while i < t.endIndex {
        let c = t[i]
        if c == "\n" { end = i; break }
        if ".!?".contains(c) {
            let n = t.index(after: i)
            if n == t.endIndex { end = n; break }
            if t[n] == " " || t[n] == "\n" {
                let after = t[n...].drop { $0 == " " || $0 == "\n" }
                if after.first.map({ $0.isUppercase || $0 == "*" || $0 == "-" }) ?? true { end = n; break }
            }
        }
        i = t.index(after: i)
    }
    let cut = end ?? t.endIndex
    let head = String(t[..<cut]).trimmingCharacters(in: .whitespaces)
    if head.count > 180 { return ("", t) }
    return (head.replacingOccurrences(of: "**", with: ""), String(t[cut...]).trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - words for triggers / tools

func humanize(_ id: String) -> String {
    let s = id.replacingOccurrences(of: "_", with: " ")
    return s.prefix(1).uppercased() + s.dropFirst()
}

/// "6.2 /min", "22 s", "45 %" for a trigger's value.
func triggerValue(_ id: String?, _ v: Double?) -> String? {
    guard let v else { return nil }
    switch id {
    case "low_blink_rate": return fmt(v, 1, suffix: " /min")
    case "long_stare": return fmt(v, 0, suffix: " s")
    case "incomplete_blinks", "drowsy": return fmt(v * 100, 0, suffix: " %")
    case "too_close": return fmt(v, 0, suffix: " cm")
    case "no_break": return duration(v)
    case "frequent_blinks": return fmt(v, 1, suffix: " /min")
    case "blink_decline": return "−" + fmt(v * 100, 0, suffix: " %")
    case "posture_drift": return v >= 2 ? "\(Int(v)) issues" : nil
    case "sustained_squint": return v > 1 ? fmt(v, 0, suffix: " s") : nil
    default: return v == 0 || v == 1 ? nil : fmt(v, v < 1 ? 2 : 0)
    }
}

/// Past-tense phrasing for a tool call, e.g. "Reminded you to blink".
func toolPhrase(_ name: String) -> String {
    [
        "remind_to_blink": "Reminded you to blink", "suggest_look_out_window": "Suggested a 20-20-20 break",
        "start_guided_eye_exercise": "Started an eye exercise", "set_dark_mode": "Changed dark mode",
        "set_increase_contrast": "Changed contrast", "set_reduce_transparency": "Reduced transparency",
        "set_reduce_motion": "Reduced motion", "set_focus_mode": "Changed Focus mode", "play_ambient_cue": "Played a soft cue",
        "switch_to_audio": "Read aloud for you", "stop_audio": "Stopped audio", "ask_user": "Asked you a question",
        "suggest_seeing_eye_doctor": "Suggested an eye check-up", "enlarge_active_window": "Enlarged the window",
        "set_display_brightness": "Adjusted screen brightness", "set_text_zoom": "Changed text size",
        "suggest_posture_reset": "Suggested a posture reset", "summarize_aloud": "Summarized the page aloud",
        "describe_screen": "Looked at the screen (on-device)", "set_cursor_size": "Changed pointer size",
    ][name] ?? humanize(name)
}

func isGoodVerdict(_ v: String?) -> Bool { ["improved", "confirmed_break"].contains(v ?? "") }
func isBadVerdict(_ v: String?) -> Bool { ["worse", "no_break"].contains(v ?? "") }
