//
//  UsagePopoverView.swift
//  ClaudeUsageBar
//
//  The SwiftUI popover. Reads UsageStore.state and renders one layout per
//  state. It never touches the network — it only invokes the closures handed
//  down from AppDelegate (brief §3, invariant 2).
//
//  Width is fixed at 300; height grows with content. Each extended row is
//  rendered only if its data is present (invariant 5: graceful degradation).
//

import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore

    var onRefresh: () -> Void
    var onLogin: () -> Void
    var onQuit: () -> Void

    /// Over this, the bar/label tints to a warning color (Phase 4 makes it a setting).
    private let warnThreshold = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch store.state {
            case .loading:
                loadingBody
            case .needsLogin:
                needsLoginBody
            case .loaded(let usage):
                loadedBody(usage)
            case .error(let message):
                errorBody(message)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.medium")
                .foregroundStyle(.secondary)
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        let color: Color
        switch store.state {
        case .loading:   color = .yellow
        case .needsLogin: color = .gray
        case .loaded(let u): color = u.sessionPercent >= warnThreshold ? .orange : .green
        case .error:     color = .red
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - Bodies

    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading usage…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var needsLoginBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not signed in")
                .font(.subheadline).fontWeight(.medium)
            Text("Sign in to claude.ai to see your current session usage.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onLogin) {
                Text("Sign in to Claude").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func loadedBody(_ usage: Usage) -> some View {
        let sessionSeries = store.history.map { Double($0.sessionPercent) }
        return VStack(alignment: .leading, spacing: 12) {
            usageBlock(title: "Session",
                       percent: usage.sessionPercent,
                       reset: usage.sessionReset)

            sparklineSection(sessionSeries,
                             warn: usage.sessionPercent >= warnThreshold)

            if let weekly = usage.weeklyPercent {
                Divider()
                usageBlock(title: "Weekly",
                           percent: weekly,
                           reset: usage.weeklyReset)
            }

            if let models = usage.perModel, !models.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("By model").font(.caption).foregroundStyle(.secondary)
                    ForEach(models) { model in
                        HStack {
                            Text(model.modelName).font(.callout)
                            Spacer()
                            Text("\(model.percent)%").font(.callout).monospacedDigit()
                        }
                    }
                }
            }

            Text("Updated \(timeStamp(usage.capturedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func errorBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't load usage", systemImage: "exclamationmark.triangle")
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign in again", action: onLogin)
                .controlSize(.regular)
        }
    }

    // MARK: - Reusable usage block (percent + bar + reset)

    private func usageBlock(title: String, percent: Int, reset: Date?) -> some View {
        let warn = percent >= warnThreshold
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(percent)%")
                    .font(.title2).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(warn ? .orange : .primary)
            }
            ProgressView(value: Double(percent), total: 100)
                .tint(warn ? .orange : .accentColor)
            if let reset {
                Text(resetText(reset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Session history sparkline

    @ViewBuilder
    private func sparklineSection(_ values: [Double], warn: Bool) -> some View {
        if values.count >= 2 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session history")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(values.count) pts")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                SparklineView(values: values, lineColor: warn ? .orange : .accentColor)
                    .frame(height: 34)
                    .accessibilityLabel("Session usage trend over recent samples")
            }
        } else {
            Text("Session history — collecting (refresh to add points)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Spacer()
            Button("Quit", action: onQuit)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .buttonStyle(.plain)
    }

    // MARK: - Formatting

    private func resetText(_ date: Date) -> String {
        let now = Date()
        if date <= now { return "Resets now" }
        let interval = date.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "Resets in \(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }

    private func timeStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Sparkline

/// A tiny usage-over-time line drawn from the in-memory history (Phase 2).
/// Auto-scales to the data's range, with a minimum span so a near-flat series
/// isn't visually magnified into dramatic swings.
private struct SparklineView: View {
    let values: [Double]            // oldest → newest
    var lineColor: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                ZStack {
                    // Subtle area fill under the line.
                    Path { path in
                        path.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(lineColor.opacity(0.12))

                    // The line itself.
                    Path { path in
                        path.move(to: pts[0])
                        pts.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(lineColor,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    // Highlight the latest sample.
                    Circle()
                        .fill(lineColor)
                        .frame(width: 4, height: 4)
                        .position(pts[pts.count - 1])
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let dataSpan = maxV - minV
        let span = max(dataSpan, 5)                  // minimum visual span
        let lo = minV - (span - dataSpan) / 2        // center the data within the span
        let n = values.count
        let inset: CGFloat = 2                        // keep the line/dot off the edges
        return values.enumerated().map { index, value in
            let x = (size.width - inset * 2) * CGFloat(index) / CGFloat(n - 1) + inset
            let norm = (value - lo) / span            // 0…1
            let y = inset + (size.height - inset * 2) * (1 - CGFloat(norm))
            return CGPoint(x: x, y: y)
        }
    }
}
