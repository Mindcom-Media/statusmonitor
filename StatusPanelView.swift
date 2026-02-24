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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.15))

            if monitor.sessions.isEmpty {
                Text("No active Claude sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(monitor.sessions) { session in
                            SessionRowView(session: session, isFlashing: alertManager.isFlashing)
                                .onTapGesture {
                                    guard !session.tty.isEmpty else { return }
                                    SessionMonitor.focusTerminalWindow(tty: session.tty)
                                }
                                .cursor(.pointingHand)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(alertManager.isFlashing ? Color.red.opacity(0.15) : Color.black.opacity(0.9))
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
        HStack(spacing: 10) {
            // Status dot with pulse rings
            ZStack {
                if session.needsAttention {
                    Circle()
                        .stroke(statusColor.opacity(0.4), lineWidth: 2)
                        .frame(width: 20, height: 20)
                        .scaleEffect(isPulsing ? 1.8 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.6)
                        .animation(
                            .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                    Circle()
                        .stroke(statusColor.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                        .scaleEffect(isPulsing ? 1.5 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.8)
                        .animation(
                            .easeOut(duration: 1.2).repeatForever(autoreverses: false).delay(0.3),
                            value: isPulsing
                        )
                }
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .scaleEffect(session.needsAttention && isFlashing ? 1.6 : 1.0)
            }
            .frame(width: 24, height: 24)
            .onAppear {
                if session.needsAttention { isPulsing = true }
            }
            .onChange(of: session.needsAttention) { newValue in
                isPulsing = newValue
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(session.needsAttention && isFlashing ? .red : .white)
                        .underline(isHovered)
                        .lineLimit(1)
                    Spacer()
                    Text(session.status.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(statusColor)
                }

                Text(session.statusDetail.isEmpty ? session.timeSinceActivity : "\(session.statusDetail) - \(session.timeSinceActivity)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
        case .idle: return Color(red: 1.0, green: 0.84, blue: 0.04)
        case .unknown: return Color.gray
        }
    }
}
