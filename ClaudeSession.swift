import Foundation

enum SessionStatus: String, CaseIterable {
    case active = "ACTIVE"
    case waiting = "WAITING"
    case idle = "IDLE"
    case unknown = "UNKNOWN"
}

struct ClaudeSession: Identifiable {
    let id: String              // Debug log UUID
    let pid: Int
    let projectPath: String
    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    var status: SessionStatus
    var lastActivityTime: Date
    var needsAttention: Bool
    var needsAttentionSince: Date?
    var statusDetail: String

    init(id: String, pid: Int, projectPath: String, status: SessionStatus = .unknown,
         lastActivityTime: Date = Date(), needsAttention: Bool = false, statusDetail: String = "") {
        self.id = id
        self.pid = pid
        self.projectPath = projectPath
        self.status = status
        self.lastActivityTime = lastActivityTime
        self.needsAttention = needsAttention
        self.statusDetail = statusDetail
    }

    var timeSinceActivity: String {
        let seconds = Int(Date().timeIntervalSince(lastActivityTime))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
