import SwiftUI

struct StatusPanelView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var alertManager: AlertManager

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
                            SessionRowView(session: session)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    alertManager.isFlashing ? Color.red : Color.white.opacity(0.15),
                    lineWidth: alertManager.isFlashing ? 2 : 1
                )
                .animation(.easeInOut(duration: 0.3).repeatCount(5, autoreverses: true), value: alertManager.isFlashing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 12)
    }
}

struct SessionRowView: View {
    let session: ClaudeSession
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .scaleEffect(session.needsAttention && isPulsing ? 1.4 : 1.0)
                .opacity(session.needsAttention && isPulsing ? 0.5 : 1.0)
                .animation(
                    session.needsAttention
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
                .onAppear {
                    if session.needsAttention { isPulsing = true }
                }
                .onChange(of: session.needsAttention) { newValue in
                    isPulsing = newValue
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(session.status.rawValue)
                        .font(.system(size: 10, weight: .medium))
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
                ? Color.red.opacity(0.08)
                : Color.clear
        )
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return Color(red: 0.2, green: 0.78, blue: 0.35)  // green
        case .waiting: return Color(red: 1.0, green: 0.23, blue: 0.19) // red
        case .idle: return Color(red: 1.0, green: 0.84, blue: 0.04)    // yellow
        case .unknown: return Color.gray
        }
    }
}
