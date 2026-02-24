import Foundation
import Combine

final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private var lastReadPositions: [String: UInt64] = [:]
    private var pidToUUID: [Int: String] = [:]
    private var previousAttentionState: [String: Bool] = [:]
    var onAttentionNeeded: (() -> Void)?

    private let debugDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/debug"
    }()

    func startMonitoring() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let discovered = self.discoverProcesses()
            self.mapPIDsToDebugLogs(pids: discovered.map(\.pid))
            let windowNames = self.getTerminalWindowNames()
            var updated: [ClaudeSession] = []

            for proc in discovered {
                guard let uuid = self.pidToUUID[proc.pid] else { continue }
                var session = self.sessions.first(where: { $0.id == uuid })
                    ?? ClaudeSession(id: uuid, pid: proc.pid, projectPath: proc.cwd, tty: proc.tty)
                session.windowName = windowNames[proc.tty] ?? ""
                session = self.updateSessionState(session: session, uuid: uuid)
                updated.append(session)
            }

            // Check for new attention transitions
            var anyNewAttention = false
            for session in updated {
                let wasAttention = self.previousAttentionState[session.id] ?? false
                if session.needsAttention && !wasAttention {
                    anyNewAttention = true
                }
                self.previousAttentionState[session.id] = session.needsAttention
            }

            // Clean up stale entries
            let activeIDs = Set(updated.map(\.id))
            self.previousAttentionState = self.previousAttentionState.filter { activeIDs.contains($0.key) }

            DispatchQueue.main.async {
                self.sessions = updated
                if anyNewAttention {
                    self.onAttentionNeeded?()
                }
            }
        }
    }

    // MARK: - Process Discovery

    private func discoverProcesses() -> [(pid: Int, cwd: String, tty: String)] {
        let psOutput = runCommand("/bin/ps", arguments: ["-eo", "pid,tty,command"])
        var claudeProcs: [(pid: Int, tty: String)] = []

        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3,
                  let pid = Int(parts[0]) else { continue }
            let cmd = parts[2].trimmingCharacters(in: .whitespaces)
            guard cmd == "claude" else { continue }
            claudeProcs.append((pid: pid, tty: parts[1]))
        }

        var results: [(pid: Int, cwd: String, tty: String)] = []
        for proc in claudeProcs {
            let lsofOutput = runCommand("/usr/sbin/lsof", arguments: ["-p", "\(proc.pid)", "-a", "-d", "cwd", "-F", "n"])
            for line in lsofOutput.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    let cwd = String(line.dropFirst())
                    results.append((pid: proc.pid, cwd: cwd, tty: proc.tty))
                    break
                }
            }
        }
        return results
    }

    /// Get Terminal window names mapped by TTY via AppleScript
    private func getTerminalWindowNames() -> [String: String] {
        let script = """
        tell application "Terminal"
            set output to ""
            set winCount to count of windows
            repeat with i from 1 to winCount
                try
                    set w to window i
                    set wName to name of w
                    repeat with t in tabs of w
                        set ttyName to tty of t
                        set output to output & ttyName & "|||" & wName & linefeed
                    end repeat
                end try
            end repeat
            return output
        end tell
        """
        let result = runCommand("/usr/bin/osascript", arguments: ["-e", script])
        var mapping: [String: String] = [:]
        for line in result.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 2 else { continue }
            // TTY from AppleScript: "/dev/ttys007", from ps: "ttys007"
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/dev/", with: "")
            mapping[tty] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return mapping
    }

    /// Focus a Terminal window by its TTY
    static func focusTerminalWindow(tty: String) {
        let devTTY = "/dev/\(tty)"
        let script = "tell application \"Terminal\"\nset winCount to count of windows\nrepeat with i from 1 to winCount\ntry\nset w to window i\nrepeat with t in tabs of w\nif tty of t is \"\(devTTY)\" then\nset frontmost of w to true\nset selected tab of w to t\nactivate\nreturn \"focused\"\nend if\nend repeat\nend try\nend repeat\nreturn \"not found\"\nend tell"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}
        }
    }

    // MARK: - Debug Log Mapping

    private func mapPIDsToDebugLogs(pids: [Int]) {
        let unmapped = pids.filter { pidToUUID[$0] == nil }
        guard !unmapped.isEmpty else { return }

        let fm = FileManager.default

        // Use grep to find all debug logs referencing each PID, then pick the
        // most recently modified match. This handles PID reuse correctly —
        // the current session's log will always be the most recently modified.
        for pid in unmapped {
            let grepOutput = runCommand("/usr/bin/grep", arguments: [
                "-rl", "-E", "(claude\\.json\\.tmp\\.\(pid)|Acquired PID lock.*PID \(pid))", debugDir
            ])
            let matchingFiles = grepOutput.components(separatedBy: "\n")
                .filter { !$0.isEmpty && $0.hasSuffix(".txt") }
                .sorted { a, b in
                    let modA = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                    let modB = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                    return modA > modB
                }
            if let bestMatch = matchingFiles.first {
                let uuid = String(URL(fileURLWithPath: bestMatch).deletingPathExtension().lastPathComponent)
                pidToUUID[pid] = uuid
            }
        }
    }

    // MARK: - State Detection

    private func updateSessionState(session: ClaudeSession, uuid: String) -> ClaudeSession {
        var session = session
        let path = "\(debugDir)/\(uuid).txt"

        guard let handle = FileHandle(forReadingAtPath: path) else {
            session.status = .unknown
            return session
        }
        defer { handle.closeFile() }

        handle.seekToEndOfFile()
        let fileSize = handle.offsetInFile

        let lastPos = lastReadPositions[uuid] ?? 0
        let readFrom: UInt64
        if lastPos > fileSize {
            readFrom = fileSize > 8192 ? fileSize - 8192 : 0
        } else if fileSize - lastPos > 8192 {
            readFrom = fileSize - 8192
        } else {
            readFrom = lastPos
        }

        handle.seek(toFileOffset: readFrom)
        let data = handle.readDataToEndOfFile()
        lastReadPositions[uuid] = fileSize

        guard let text = String(data: data, encoding: .utf8) else {
            session.status = .unknown
            return session
        }

        let lines = text.components(separatedBy: "\n")

        var lastPermissionPrompt: Date?
        var lastStreamStarted: Date?
        var lastToolHook: Date?
        var lastSpawningShell: Date?
        var lastLogTimestamp: Date?

        for line in lines {
            guard let ts = parseTimestamp(line) else { continue }
            lastLogTimestamp = ts

            if line.contains("Notification with query: permission_prompt") {
                lastPermissionPrompt = ts
            } else if line.contains("Stream started") {
                lastStreamStarted = ts
            } else if line.contains("executePreToolHooks called") {
                lastToolHook = ts
            } else if line.contains("Spawning shell") {
                lastSpawningShell = ts
            }
        }

        let now = Date()
        let mostRecentWork = [lastStreamStarted, lastToolHook, lastSpawningShell].compactMap { $0 }.max()

        if let permTime = lastPermissionPrompt,
           (mostRecentWork == nil || permTime > mostRecentWork!) {
            session.status = .waiting
            session.needsAttention = true
            session.statusDetail = "Needs permission"
            if session.needsAttentionSince == nil {
                session.needsAttentionSince = permTime
            }
        } else if let lastLog = lastLogTimestamp, now.timeIntervalSince(lastLog) > 60 {
            session.status = .idle
            session.needsAttention = true
            session.statusDetail = "No activity \(formatDuration(now.timeIntervalSince(lastLog)))"
            if session.needsAttentionSince == nil {
                session.needsAttentionSince = lastLog
            }
        } else if let workTime = mostRecentWork, let lastLog = lastLogTimestamp,
                  now.timeIntervalSince(lastLog) < 30 {
            session.status = .active
            session.needsAttention = false
            session.needsAttentionSince = nil
            if lastSpawningShell != nil && lastSpawningShell == workTime {
                session.statusDetail = "Running command..."
            } else if lastToolHook != nil && lastToolHook == workTime {
                session.statusDetail = "Using tools..."
            } else {
                session.statusDetail = "Working..."
            }
        } else {
            session.status = .active
            session.needsAttention = false
            session.needsAttentionSince = nil
            session.statusDetail = "Working..."
        }

        session.lastActivityTime = lastLogTimestamp ?? session.lastActivityTime
        return session
    }

    // MARK: - Helpers

    private func parseTimestamp(_ line: String) -> Date? {
        guard line.count > 24, line[line.index(line.startIndex, offsetBy: 4)] == "-" else { return nil }
        let tsString = String(line.prefix(24))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: tsString)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        return "\(h)h"
    }

    private func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Read data BEFORE waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
