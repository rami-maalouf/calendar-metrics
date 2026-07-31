//
//  MenuBarView.swift
//  Intent
//
//  Created by Codex on 2026-03-10.
//

import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: IntentAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Intent")
                .font(.headline)

            Text(model.connectionStatus)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Current session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.currentSessionTitle)
                    .lineLimit(2)
            }

            if model.pendingReviewsCount > 0 {
                Text("\(model.pendingReviewsCount) open reflection\(model.pendingReviewsCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open dashboard") {
                openWindow(id: "main")
            }

            Button("Pull Toggl") {
                Task {
                    await model.pullNow()
                }
            }

            Button("Generate report") {
                Task {
                    await model.generateLatestCompletedDailyReport()
                }
            }

            Button("Reconnect live sync") {
                Task {
                    await model.pollOnce()
                }
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280)
        .task {
            model.start()
        }
    }
}
