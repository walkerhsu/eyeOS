import AppKit
import Foundation

/// Spawns and supervises the Python sidecar and owns the WebSocket to it (SPEC §2 "Sidecar lifecycle").
final class Sidecar {
    static let devRepo: String = {
        // …/eyeOS/app/Sources/eyeOS/Sidecar.swift → …/eyeOS
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
    }()

    var repoPath: String { UserDefaults.standard.string(forKey: "sidecar.repo_path") ?? Self.devRepo }
    var onMessage: (J) -> Void = { _ in }
    var onFrame: (Data) -> Void = { _ in }
    var onConnected: (Bool) -> Void = { _ in }
    var onFatal: (String) -> Void = { _ in }

    private var proc: Process?
    private var stdinPipe: Pipe?
    private var ws: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var port = 8765
    private var token = ""
    private var stderrTail: [String] = []
    private var failures: [Date] = []
    private var quitting = false
    private var generation = 0

    func start() {
        quitting = false
        generation += 1
        let gen = generation
        #if DEBUG
        port = 8765
        #else
        port = Int.random(in: 20000...60000)
        #endif
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        guard let uv = Self.find("uv") else {
            onFatal("Couldn't find `uv`. Install it with `brew install uv`.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--project", repoPath + "/sidecar", "python", "-m", "eyeos", "--port", "\(port)", "--token", token]
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath + "/sidecar")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPath
        for (k, acct) in [("CARTESIA_API_KEY", "cartesia"), ("ANTHROPIC_API_KEY", "anthropic")] {
            if let v = Keychain.get(acct), !v.isEmpty { env[k] = v } else { env.removeValue(forKey: k) }
        }
        p.environment = env
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        stdinPipe = Pipe()  // closes when the app dies, which tells the sidecar to exit
        p.standardInput = stdinPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail += s.split(separator: "\n").map(String.init)
                self.stderrTail = Array(self.stderrTail.suffix(50))
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.exited(gen) }
        }
        do { try p.run() } catch {
            onFatal("Failed to start sidecar: \(error.localizedDescription)")
            return
        }
        proc = p
        connect(gen, attempt: 0)
    }

    private func exited(_ gen: Int) {
        guard gen == generation, !quitting else { return }
        onConnected(false)
        failures = failures.filter { $0.timeIntervalSinceNow > -120 } + [Date()]
        if failures.count >= 3 {
            onFatal("The sidecar crashed 3 times in 2 minutes.\n\n" + stderrTail.joined(separator: "\n"))
            return
        }
        let delay = [1.0, 3.0, 10.0][min(failures.count - 1, 2)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    private func connect(_ gen: Int, attempt: Int) {
        guard gen == generation, !quitting, proc?.isRunning == true else { return }
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/?token=\(token)")!)
        task.maximumMessageSize = 1 << 23
        ws = task
        task.resume()
        receive(task, gen: gen, attempt: attempt)
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int, attempt: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, task === self.ws else { return }
                switch result {
                case .success(let msg):
                    switch msg {
                    case .string(let s):
                        if let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? J {
                            if j.str("type") == "hello" { self.onConnected(true) }
                            self.onMessage(j)
                        }
                    case .data(let d):
                        if d.count > 8 { self.onFrame(d.subdata(in: 8..<d.count)) }
                    @unknown default: break
                    }
                    self.receive(task, gen: gen, attempt: 0)
                case .failure:
                    self.onConnected(false)
                    // the sidecar takes a few seconds to import MediaPipe; keep retrying while it runs
                    DispatchQueue.main.asyncAfter(deadline: .now() + (attempt < 20 ? 0.5 : 2)) {
                        self.connect(gen, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    func send(_ msg: J) {
        guard let d = try? JSONSerialization.data(withJSONObject: msg), let s = String(data: d, encoding: .utf8) else { return }
        ws?.send(.string(s)) { _ in }
    }

    func command(_ name: String, _ args: J? = nil) {
        var m: J = ["type": "command", "name": name]
        if let args { m["args"] = args }
        send(m)
    }

    func restart() {
        stop(wait: true)
        failures = []
        start()
    }

    /// Sends `command:shutdown`, waits up to 2 s, then SIGTERM.
    func stop(wait: Bool) {
        quitting = true
        command("shutdown")
        guard let p = proc else { return }
        if wait {
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(50_000) }
        }
        if p.isRunning { p.terminate() }
        ws?.cancel(with: .goingAway, reason: nil)
        proc = nil
    }

    static var searchPath: String {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
    }

    static func find(_ tool: String) -> String? {
        searchPath.split(separator: ":").map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
