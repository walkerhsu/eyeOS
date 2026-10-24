import Foundation
import SwiftUI

/// Protocol messages are kept as JSON dictionaries (SPEC §6 is the schema); these helpers read them.
typealias J = [String: Any]

/// The Command Line Tools ship without the SwiftUI macro plugin, and `@State` resolves to a macro there.
/// Naming the property-wrapper struct directly builds with or without Xcode.
typealias StateVar = SwiftUICore.State

extension Dictionary where Key == String, Value == Any {
    func num(_ k: String) -> Double? {
        if let v = self[k] as? Double { return v }
        if let v = self[k] as? Int { return Double(v) }
        if let v = self[k] as? NSNumber, !(self[k] is Bool) { return v.doubleValue }
        return nil
    }
    func int(_ k: String) -> Int? { num(k).map { Int($0) } }
    func str(_ k: String) -> String? { self[k] as? String }
    func bool(_ k: String) -> Bool { (self[k] as? Bool) ?? false }
    func obj(_ k: String) -> J? { self[k] as? J }
    func arr(_ k: String) -> [J] { (self[k] as? [J]) ?? [] }
    func arr0(_ k: String) -> [String] { (self[k] as? [String]) ?? [] }
}

func fmt(_ v: Double?, _ digits: Int = 0, suffix: String = "") -> String {
    guard let v else { return "–" }
    return String(format: "%.\(digits)f", v) + suffix
}

func clock(_ ts: Double?) -> String {
    guard let ts else { return "" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

enum Level { case good, warn, bad, none
    var color: Color {
        switch self { case .good: .mint; case .warn: .orange; case .bad: .pink; case .none: .secondary }
    }
    var label: String {
        switch self { case .good: "Good"; case .warn: "Watch"; case .bad: "High"; case .none: "—" }
    }
}

/// "1h 12m", "12m", "45s"
func duration(_ s: Double?) -> String {
    guard let s else { return "–" }
    let m = Int(s) / 60
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    return m > 0 ? "\(m)m" : "\(Int(s))s"
}

/// A metric the Live page can plot. `scale` converts the raw value to the displayed unit.
struct MetricDef: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let unit: String
    let color: Color
    var scale = 1.0
    var digits = 0
    var domain: ClosedRange<Double>? = nil
    var limit: Double? = nil            // dashed "watch" line, in display units
    var baselineKey: String? = nil

    static let all: [MetricDef] = [
        .init(id: "eye_score", title: "Eye score", icon: "heart.text.square", unit: "", color: .mint, domain: 0...100, limit: 60),
        .init(id: "blink_rate", title: "Blink rate", icon: "eye", unit: "/min", color: .teal, digits: 1, limit: 8, baselineKey: "blink_rate"),
        .init(id: "openness", title: "Eye openness (live)", icon: "waveform.path", unit: "", color: .cyan, digits: 2, domain: 0...1.2),
        .init(id: "incomplete_pct", title: "Incomplete blinks", icon: "circle.lefthalf.filled", unit: "%", color: .orange, scale: 100,
              domain: 0...100, limit: 40),
        .init(id: "current_stare_s", title: "Stare", icon: "timer", unit: "s", color: .yellow, limit: 15),
        .init(id: "perclos", title: "Drowsiness", icon: "moon.zzz", unit: "%", color: .purple, scale: 100, digits: 1, limit: 15),
        .init(id: "distance_cm", title: "Screen distance", icon: "ruler", unit: "cm", color: .blue, limit: 40, baselineKey: "distance_cm"),
        .init(id: "squint_delta", title: "Squint", icon: "sun.max", unit: "", color: .pink, digits: 2),
        .init(id: "since_real_break_s", title: "Since last break", icon: "cup.and.saucer", unit: "min", color: .green, scale: 1.0 / 60,
              limit: 20),
        .init(id: "gaze_on_screen", title: "Eyes on screen", icon: "scope", unit: "%", color: .indigo, scale: 100, domain: 0...100),
        .init(id: "posture", title: "Posture", icon: "figure.stand", unit: "", color: .green),
    ]
    static func get(_ id: String) -> MetricDef { all.first { $0.id == id } ?? all[1] }
}

/// Status color for a "higher is better" value (≥ good → green, ≥ warn → amber).
func levelHigh(_ v: Double?, good: Double, warn: Double) -> Level {
    guard let v else { return .none }
    return v >= good ? .good : v >= warn ? .warn : .bad
}

/// Status color for a "lower is better" value (< good → green, ≤ warn → amber).
func levelLow(_ v: Double?, good: Double, warn: Double) -> Level {
    guard let v else { return .none }
    return v < good ? .good : v <= warn ? .warn : .bad
}

struct RunRow: Identifiable {
    let id: Int
    var ts: Double
    var triggers: [J] = []
    var thinking: [String] = []
    var texts: [String] = []
    var calls: [Int: J] = [:]
    var status = "started"
    var inputTokens: Int?
    var outputTokens: Int?
    var latency: Double?
    var error: String?
    var sortedCalls: [J] { calls.keys.sorted().compactMap { calls[$0] } }
}

let toolIcons: [String: String] = [
    "set_dark_mode": "moon.fill", "set_increase_contrast": "circle.lefthalf.filled", "set_reduce_transparency": "square.on.square",
    "set_reduce_motion": "figure.walk", "set_focus_mode": "moon.zzz.fill", "remind_to_blink": "eye",
    "suggest_look_out_window": "window.vertical.open", "start_guided_eye_exercise": "figure.mind.and.body",
    "play_ambient_cue": "bell", "switch_to_audio": "speaker.wave.2.fill", "stop_audio": "speaker.slash",
    "ask_user": "questionmark.bubble", "suggest_seeing_eye_doctor": "stethoscope", "enlarge_active_window": "macwindow",
    "set_display_brightness": "sun.max", "set_text_zoom": "textformat.size", "suggest_posture_reset": "figure.stand",
    "summarize_aloud": "text.bubble", "describe_screen": "lock.display", "set_cursor_size": "cursorarrow.rays",
]
