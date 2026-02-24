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
            var updated: [ClaudeSession] = []

            for (pid, cwd) in discovered {
                guard let uuid = self.pidToUUID[pid] else { continue }
                var session = self.sessions.first(where: { $0.id == uuid })
                    ?? ClaudeSession(id: uuid, pid: pid, projectPath: cwd)
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

    private func discoverProcesses() -> [(pid: Int, cwd: String)] {
        let psOutput = runCommand("/bin/ps", arguments: ["-eo", "pid,command"])
        var claudePIDs: [Int] = []

        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines like "47050 claude" (exact command name)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = Int(parts[0]),
                  parts[1] == "claude" else { continue }
            claudePIDs.append(pid)
        }

        var results: [(pid: Int, cwd: String)] = []
        for pid in claudePIDs {
            let lsofOutput = runCommand("/usr/sbin/lsof", arguments: ["-p", "\(pid)", "-a", "-d", "cwd", "-F", "n"])
            for line in lsofOutput.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    let cwd = String(line.dropFirst())
                    results.append((pid: pid, cwd: cwd))
                    break
                }
            }
        }
        return results
    }

    // MARK: - Debug Log Mapping

    private func mapPIDsToDebugLogs(pids: [Int]) {
        let unmapped = pids.filter { pidToUUID[$0] == nil }
        guard !unmapped.isEmpty else { return }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: debugDir) else { return }

        for file in files where file.hasSuffix(".txt") {
            let uuid = String(file.dropLast(4))
            // Skip if already mapped to a PID
            if pidToUUID.values.contains(uuid) { continue }

            let path = "\(debugDir)/\(file)"
            // Only read first 2KB to find the PID lock line
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { handle.closeFile() }
            let headerData = handle.readData(ofLength: 2048)
            guard let header = String(data: headerData, encoding: .utf8) else { continue }

            for pid in unmapped {
                if header.contains("Acquired PID lock") && header.contains("PID \(pid)") {
                    pidToUUID[pid] = uuid
                }
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

        // Get file size
        handle.seekToEndOfFile()
        let fileSize = handle.offsetInFile

        // Determine read position - read last 8KB or from last position
        let lastPos = lastReadPositions[uuid] ?? 0
        let readFrom: UInt64
        if lastPos > fileSize {
            // File was rotated
            readFrom = fileSize > 8192 ? fileSize - 8192 : 0
        } else if fileSize - lastPos > 8192 {
            // Too much new data, just read last 8KB
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

        // Find timestamps and key events in the tail
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

        // Determine status based on most recent events
        let now = Date()
        let mostRecentWork = [lastStreamStarted, lastToolHook, lastSpawningShell].compactMap { $0 }.max()

        if let permTime = lastPermissionPrompt,
           (mostRecentWork == nil || permTime > mostRecentWork!) {
            // Permission prompt is the most recent significant event
            session.status = .waiting
            session.needsAttention = true
            session.statusDetail = "Needs permission"
            if session.needsAttentionSince == nil {
                session.needsAttentionSince = permTime
            }
        } else if let lastLog = lastLogTimestamp, now.timeIntervalSince(lastLog) > 60 {
            // No activity for 60+ seconds
            session.status = .idle
            session.needsAttention = true
            session.statusDetail = "No activity \(formatDuration(now.timeIntervalSince(lastLog)))"
            if session.needsAttentionSince == nil {
                session.needsAttentionSince = lastLog
            }
        } else if let workTime = mostRecentWork, let lastLog = lastLogTimestamp,
                  now.timeIntervalSince(lastLog) < 30 {
            // Recent work activity
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
        // Format: 2026-02-24T09:57:08.673Z
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
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
