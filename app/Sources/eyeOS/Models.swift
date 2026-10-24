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
        switch self { case .good: .green; case .warn: .orange; case .bad: .red; case .none: .secondary }
    }
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
]
