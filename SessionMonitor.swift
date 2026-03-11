import Foundation
import Combine

final class SessionMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []

    private var timer: Timer?
    private var pidToUUID: [Int: String] = [:]
    private var previousAttentionState: [String: Bool] = [:]
    enum AttentionType {
        case permission  // Needs user to confirm/approve something
        case done        // Finished working, waiting for next input
    }
    var onAttentionNeeded: ((AttentionType) -> Void)?

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
            let cwds = Dictionary(discovered.map { ($0.pid, $0.cwd) }, uniquingKeysWith: { first, _ in first })
            self.mapPIDsToDebugLogs(pids: discovered.map(\.pid), cwds: cwds)
            let terminalInfo = self.getTerminalInfo()
            var updated: [ClaudeSession] = []

            for proc in discovered {
                guard let uuid = self.pidToUUID[proc.pid] else { continue }
                var session = self.sessions.first(where: { $0.id == uuid })
                    ?? ClaudeSession(id: uuid, pid: proc.pid, projectPath: proc.cwd, tty: proc.tty)
                let info = terminalInfo[proc.tty]
                session.windowName = info?.windowName ?? ""
                session = self.updateFromTerminal(session: session, screenContent: info?.screenContent ?? "")
                updated.append(session)
            }

            // Check for new attention transitions
            var newPermission = false
            var newDone = false
            for session in updated {
                let wasAttention = self.previousAttentionState[session.id] ?? false
                if session.needsAttention && !wasAttention {
                    if session.status == .waiting {
                        newPermission = true
                    } else {
                        newDone = true
                    }
                }
                self.previousAttentionState[session.id] = session.needsAttention
            }

            // Clean up stale entries
            let activeIDs = Set(updated.map(\.id))
            self.previousAttentionState = self.previousAttentionState.filter { activeIDs.contains($0.key) }

            DispatchQueue.main.async {
                self.sessions = updated
                // Permission alerts take priority over done alerts
                if newPermission {
                    self.onAttentionNeeded?(.permission)
                } else if newDone {
                    self.onAttentionNeeded?(.done)
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
            guard cmd == "claude" || cmd.hasPrefix("claude ") else { continue }
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

    struct TerminalInfo {
        var windowName: String = ""
        var screenContent: String = ""
    }

    /// Get Terminal window names and screen content mapped by TTY via AppleScript
    private func getTerminalInfo() -> [String: TerminalInfo] {
        let script = """
        tell application "Terminal"
            set output to ""
            set winCount to count of windows
            repeat with i from 1 to winCount
                try
                    set w to window i
                    set wName to name of w
                    set selTab to selected tab of w
                    set ttyName to tty of selTab
                    set c to history of selTab
                    set cLen to length of c
                    if cLen > 500 then
                        set snippet to text (cLen - 499) thru cLen of c
                    else
                        set snippet to c
                    end if
                    set output to output & ttyName & "|||" & wName & "|||" & snippet & "###ENDTAB###" & linefeed
                end try
            end repeat
            return output
        end tell
        """
        let result = runCommand("/usr/bin/osascript", arguments: ["-e", script])
        var mapping: [String: TerminalInfo] = [:]
        for entry in result.components(separatedBy: "###ENDTAB###") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/dev/", with: "")
            var info = TerminalInfo()
            info.windowName = parts[1].trimmingCharacters(in: .whitespaces)
            if parts.count >= 3 {
                info.screenContent = parts[2...].joined(separator: "|||")
            }
            mapping[tty] = info
        }
        return mapping
    }

    /// Legacy wrapper for backward compatibility
    private func getTerminalWindowNames() -> [String: String] {
        let info = getTerminalInfo()
        return info.mapValues { $0.windowName }
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

    private func mapPIDsToDebugLogs(pids: [Int], cwds: [Int: String]) {
        let unmapped = pids.filter { pidToUUID[$0] == nil }
        guard !unmapped.isEmpty else { return }

        let fm = FileManager.default

        // Strategy 1: grep debug logs for PID references
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

        // Strategy 2: for still-unmapped PIDs, find the most recently modified
        // JSONL conversation file in the project directory matching their CWD.
        // Path format: ~/.claude/projects/-Users-foo-repos-bar/<uuid>.jsonl
        let home = fm.homeDirectoryForCurrentUser.path
        let projectsDir = "\(home)/.claude/projects"
        let stillUnmapped = pids.filter { pidToUUID[$0] == nil }
        for pid in stillUnmapped {
            guard let cwd = cwds[pid] else { continue }
            let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
            let projectDir = "\(projectsDir)/\(projectKey)"
            guard let contents = try? fm.contentsOfDirectory(atPath: projectDir) else { continue }
            let jsonlFiles = contents.filter { $0.hasSuffix(".jsonl") }
                .map { "\(projectDir)/\($0)" }
                .sorted { a, b in
                    let modA = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                    let modB = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                    return modA > modB
                }
            if let bestMatch = jsonlFiles.first {
                let uuid = String(URL(fileURLWithPath: bestMatch).deletingPathExtension().lastPathComponent)
                pidToUUID[pid] = uuid
            }
        }

        // Strategy 3: for any remaining unmapped PIDs, use a synthetic UUID
        // so the session still appears in the UI
        for pid in pids where pidToUUID[pid] == nil {
            pidToUUID[pid] = "pid-\(pid)"
        }
    }

    // MARK: - State Detection (Terminal Screen Content)

    /// Detect session state by reading the actual terminal screen content.
    /// This is more reliable than debug logs or JSONL timestamps.
    private func updateFromTerminal(session: ClaudeSession, screenContent: String) -> ClaudeSession {
        var session = session
        let content = screenContent

        if content.isEmpty {
            session.status = .unknown
            session.needsAttention = false
            session.statusDetail = "No terminal data"
            return session
        }

        // Check for permission prompt — Claude is asking user to approve something
        // Patterns: "Allow", "Yes / No", "approve", permission-related UI
        let permissionPatterns = [
            "Allow Claude",
            "allow this action",
            "Yes / No",
            "[Y]es",
            "(Y)es",
            "yes/no",
            "Do you want to",
            "permission",
            "approve this"
        ]
        let hasPermissionPrompt = permissionPatterns.contains { pattern in
            content.range(of: pattern, options: .caseInsensitive) != nil
        }

        // Check for active work — Claude is currently processing
        // Look for spinner/progress indicators or "Working", "Running", etc.
        let activePatterns = [
            "Meandering",
            "Brewing",
            "Crunching",
            "Thinking",
            "Working",
            "Running",
            "Compacting",
            "Planning",
            "Reasoning",
            "Analyzing",
            "Searching",
            "Generating",
            "Formatting",
            "Indexing"
        ]
        // Active indicators appear near the end of the content, typically as status text
        // Only check the last 200 chars for active status
        let tail = String(content.suffix(200))
        let isActive = activePatterns.contains { pattern in
            tail.range(of: pattern, options: .caseInsensitive) != nil
        }

        // Check for idle prompt — the ❯ prompt means Claude finished and awaits input
        let isAtPrompt = tail.contains("❯") && !isActive

        if hasPermissionPrompt {
            session.status = .waiting
            session.needsAttention = true
            session.statusDetail = "Needs permission"
            if session.needsAttentionSince == nil {
                session.needsAttentionSince = Date()
            }
        } else if isActive {
            session.status = .active
            session.needsAttention = false
            session.needsAttentionSince = nil
            // Try to extract what Claude is doing
            if let match = activePatterns.first(where: { tail.range(of: $0, options: .caseInsensitive) != nil }) {
                session.statusDetail = "\(match)..."
            } else {
                session.statusDetail = "Working..."
            }
            session.lastActivityTime = Date()
        } else if isAtPrompt {
            session.status = .idle
            session.needsAttention = true
            session.statusDetail = "Waiting for input"
            if session.needsAttentionSince == nil {
                session.needsAttentionSince = Date()
            }
        } else {
            session.status = .active
            session.needsAttention = false
            session.needsAttentionSince = nil
            session.statusDetail = "Working..."
            session.lastActivityTime = Date()
        }

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
