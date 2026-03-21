import SwiftUI

struct StatusPanelView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var alertManager: AlertManager

    private var anyNeedsAttention: Bool {
        monitor.sessions.contains { $0.needsAttention }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("StatusMonitor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(monitor.sessions.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().background(Color.white.opacity(0.15))

            if monitor.sessions.isEmpty {
                Text("No active Claude sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                // Show ALL sessions — no scroll constraint
                VStack(spacing: 0) {
                    ForEach(monitor.sessions) { session in
                        SessionRowView(session: session, isFlashing: alertManager.isFlashing)
                            .onTapGesture {
                                guard !session.tty.isEmpty else { return }
                                SessionMonitor.focusTerminalWindow(tty: session.tty)
                            }
                            .cursor(.pointingHand)

                        if session.id != monitor.sessions.last?.id {
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(alertManager.isFlashing ? Color.red.opacity(0.15) : Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    alertManager.isFlashing ? Color.red : (anyNeedsAttention ? Color.red.opacity(0.5) : Color.white.opacity(0.15)),
                    lineWidth: alertManager.isFlashing ? 3 : (anyNeedsAttention ? 2 : 1)
                )
        )
        .shadow(color: alertManager.isFlashing ? Color.red.opacity(0.6) : .black.opacity(0.4),
                radius: alertManager.isFlashing ? 20 : 12)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// Cursor modifier for macOS
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

struct SessionRowView: View {
    let session: ClaudeSession
    let isFlashing: Bool
    @State private var isPulsing = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Status dot with pulse rings
            ZStack {
                if session.needsAttention {
                    Circle()
                        .stroke(statusColor.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                        .scaleEffect(isPulsing ? 1.8 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.6)
                        .animation(
                            .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                    Circle()
                        .stroke(statusColor.opacity(0.6), lineWidth: 1)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isPulsing ? 1.5 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.8)
                        .animation(
                            .easeOut(duration: 1.2).repeatForever(autoreverses: false).delay(0.3),
                            value: isPulsing
                        )
                }
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(session.needsAttention && isFlashing ? 1.6 : 1.0)
            }
            .frame(width: 18, height: 18)
            .onAppear {
                if session.needsAttention { isPulsing = true }
            }
            .onChange(of: session.needsAttention) { newValue in
                isPulsing = newValue
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.projectName.count > 12 ? String(session.projectName.prefix(12)) + "…" : session.projectName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(session.needsAttention && isFlashing ? .red : .white)
                        .underline(isHovered)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.status.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(statusColor.opacity(0.15))
                        )
                }

                Text(session.statusDetail)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            session.needsAttention
                ? (isFlashing ? Color.red.opacity(0.2) : Color.red.opacity(0.08))
                : (isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return Color(red: 0.2, green: 0.78, blue: 0.35)
        case .waiting: return Color(red: 1.0, green: 0.23, blue: 0.19)
        case .idle: return session.needsAttention
            ? Color(red: 1.0, green: 0.4, blue: 0.1)  // Orange-red when needs attention
            : Color(red: 0.2, green: 0.5, blue: 1.0)   // Blue otherwise
        case .unknown: return Color.gray
        }
    }
}
