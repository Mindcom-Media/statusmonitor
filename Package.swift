// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StatusMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StatusMonitor",
            path: ".",
            exclude: ["Info.plist"],
            sources: [
                "StatusMonitorApp.swift",
                "StatusPanelWindow.swift",
                "StatusPanelView.swift",
                "SessionMonitor.swift",
                "ClaudeSession.swift",
                "AlertManager.swift"
            ],
            resources: [
                .copy("alert.mp3")
            ]
        )
    ]
)
