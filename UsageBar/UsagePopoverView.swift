//
//  UsagePopoverView.swift
//  UsageBar
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
    @ObservedObject var settings: AppSettings

    var onRefresh: () -> Void
    var onLogin: () -> Void
    var onSignOut: () -> Void
    var onQuit: () -> Void

    /// Over this, the bar/label tints to a warning color. Sourced from settings.
    private var warnThreshold: Int { settings.warnThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            menuBarModeRow
            footer

            if settings.settingsExpanded {
                Divider()
                settingsPanel
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.medium")
                .foregroundStyle(.secondary)
            Text("Usage Bar")
                .font(.headline)
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        let color: Color
        var warn = false
        switch store.state {
        case .loading:   color = .yellow
        case .needsLogin: color = .gray
        case .loaded(let u):
            warn = u.sessionPercent >= warnThreshold
            color = warn ? .orange : .green
        case .error:     color = .red
        }
        // A symbol rather than a Circle so it can breathe when you're over the
        // warning threshold; visually identical otherwise.
        return Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(color)
            .pulsing(warn)
    }

    /// A section heading: a small tertiary symbol plus its label. The fixed icon
    /// width keeps every heading's text on the same left edge.
    private func sectionLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 11)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The same idea at settings-row scale.
    private func settingLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text(title).foregroundStyle(.secondary)
        }
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
                Text("Sign in to claude.ai").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func loadedBody(_ usage: Usage) -> some View {
        let sessionSeries = store.history.map { Double($0.sessionPercent) }
        return VStack(alignment: .leading, spacing: 8) {
            usageBlock(icon: "hourglass", title: "Session",
                       percent: usage.sessionPercent,
                       reset: usage.sessionReset)

            sparklineSection(sessionSeries,
                             warn: usage.sessionPercent >= warnThreshold)

            if let weekly = usage.weeklyPercent {
                Divider()
                usageBlock(icon: "calendar", title: "Weekly",
                           percent: weekly,
                           reset: usage.weeklyReset)
            }

            if let models = usage.perModel, !models.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("cpu", "By model")
                    ForEach(models) { model in
                        HStack {
                            Text(model.modelName).font(.callout)
                            Spacer()
                            Text("\(model.percent)%").font(.callout).monospacedDigit()
                        }
                    }
                }
            }

            if let credits = usage.credits {
                Divider()
                creditsBlock(credits)
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

    private func usageBlock(icon: String, title: String, percent: Int, reset: Date?) -> some View {
        let warn = percent >= warnThreshold
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel(icon, title)
                Spacer()
                Text("\(percent)%")
                    .font(.title3).fontWeight(.semibold).monospacedDigit()
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

    // MARK: - Credits (pay-as-you-go "extra usage")

    private func creditsBlock(_ credits: CreditUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("creditcard", "Credits")
                Spacer()
                Text(money(credits.used, credits.currency))
                    .font(.title3).fontWeight(.semibold).monospacedDigit()
            }
            ProgressView(value: min(credits.used, credits.limit),
                         total: max(credits.limit, 0.01))
            Text("of \(money(credits.limit, credits.currency)) this month")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Session history sparkline

    @ViewBuilder
    private func sparklineSection(_ values: [Double], warn: Bool) -> some View {
        if values.count >= 2 {
            SparklineView(values: values, lineColor: warn ? .orange : .accentColor)
                .frame(height: 22)
                .accessibilityLabel("Session usage trend over recent samples")
        } else {
            Text("Session history — collecting (refresh to add points)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Menu bar mode

    private var menuBarModeRow: some View {
        HStack(spacing: 6) {
            sectionLabel("menubar.rectangle", "Menu bar")
            Spacer()
            Picker("", selection: $settings.menuBarMode) {
                ForEach(MenuBarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    // MARK: - Inline settings panel (toggled by the footer gear; expands the popover under the layout)

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.launchAtLogin) { settingLabel("power", "Launch at login") }
            Toggle(isOn: $settings.showInDock) { settingLabel("dock.rectangle", "Show in Dock") }
            HStack {
                settingLabel("paintpalette", "Menu bar color")
                Spacer()
                Picker("", selection: $settings.menuBarColor) {
                    ForEach(MenuBarColor.allCases) { color in
                        Text(color.label).tag(color)
                    }
                }
                .labelsHidden().fixedSize()
            }
            HStack {
                settingLabel("arrow.clockwise", "Refresh every")
                Spacer()
                Picker("", selection: $settings.refreshIntervalMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 min" : "\(minutes) min").tag(minutes)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Stepper(value: $settings.warnThreshold, in: 50...95, step: 5) {
                settingLabel("exclamationmark.triangle", "Warning at \(settings.warnThreshold)%")
            }
            Button("Sign out", role: .destructive, action: onSignOut)
                .padding(.top, 2)
        }
        .controlSize(.small)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: onRefresh) {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise").spinning(store.isRefreshing)
                }
            }
            Spacer()
            Button {
                settings.settingsExpanded.toggle()
            } label: {
                Label("Settings", systemImage: settings.settingsExpanded ? "gearshape.fill" : "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("Settings")
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

    private func money(_ amount: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        // Pin to a consistent symbol-prefix format ("$18.77") rather than the
        // host locale's convention (which can render "18,77 US$").
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
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

// MARK: - Symbol effects

/// Symbol effects arrived in macOS 14 and `.rotate` in macOS 15, so these wrap
/// the availability dance and simply don't animate on macOS 13.
private struct SpinWhileActive: ViewModifier {
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.rotate, options: .repeating, isActive: active)
        } else if #available(macOS 14.0, *) {
            content.symbolEffect(.pulse, options: .repeating, isActive: active)
        } else {
            content
        }
    }
}

private struct PulseWhileActive: ViewModifier {
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.pulse, options: .repeating, isActive: active)
        } else {
            content
        }
    }
}

private extension View {
    /// Spins while a refresh is actually in flight.
    func spinning(_ active: Bool) -> some View { modifier(SpinWhileActive(active: active)) }
    /// Breathes while the value is over the warning threshold.
    func pulsing(_ active: Bool) -> some View { modifier(PulseWhileActive(active: active)) }
}
