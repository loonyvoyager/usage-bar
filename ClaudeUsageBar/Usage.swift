//
//  Usage.swift
//  ClaudeUsageBar
//
//  The model layer. Plain, typed Swift values + an observable store.
//  This file knows NOTHING about URLs, JSON keys, or cookies — that all
//  lives in ClaudeSession.swift (see CLAUDE_CODE_BRIEF.md §3, invariant 1).
//
//  State flows one way:  ClaudeSession → UsageStore.state (enum) → UI.
//

import Foundation
import Combine

/// One model's slice of usage (e.g. Opus vs Sonnet). Phase 2 / optional.
struct ModelUsage: Identifiable, Equatable {
    /// Stable identity so SwiftUI lists diff cleanly and Equatable is meaningful.
    var id: String { modelName }
    let modelName: String
    /// 0…100, already normalized by ClaudeSession.
    let percent: Int
}

/// Pay-as-you-go "extra usage" credit pool (optional). Amounts are already in
/// currency units (e.g. dollars), converted from the endpoint's minor units by
/// ClaudeSession — the UI just formats them.
struct CreditUsage: Equatable {
    let used: Double
    let limit: Double
    let currency: String   // ISO code, e.g. "USD"
}

/// A single usage sample. Required fields describe the active *session* window;
/// every "extended" field is optional so the UI can hide rows it has no data for
/// (brief §3, invariant 5: graceful degradation).
struct Usage: Equatable {
    /// Session window utilization, 0…100.
    var sessionPercent: Int
    /// When the session window resets, if the endpoint exposes it.
    var sessionReset: Date?

    // --- Extended, optional (Phase 2). Parsing fills only what it finds. ---
    var weeklyPercent: Int?
    var weeklyReset: Date?
    var perModel: [ModelUsage]?
    var credits: CreditUsage?

    /// When this sample was captured locally (for the "last updated" stamp).
    var capturedAt: Date

    init(sessionPercent: Int,
         sessionReset: Date? = nil,
         weeklyPercent: Int? = nil,
         weeklyReset: Date? = nil,
         perModel: [ModelUsage]? = nil,
         credits: CreditUsage? = nil,
         capturedAt: Date = Date()) {
        self.sessionPercent = sessionPercent
        self.sessionReset = sessionReset
        self.weeklyPercent = weeklyPercent
        self.weeklyReset = weeklyReset
        self.perModel = perModel
        self.credits = credits
        self.capturedAt = capturedAt
    }
}

/// Failure is a state, not a crash (brief §3, invariant 6). Everything the UI
/// can be in is one of these cases.
enum UsageState: Equatable {
    case loading
    case needsLogin
    case loaded(Usage)
    case error(String)
}

/// The single source of truth the UI observes. `AppDelegate` pushes new states
/// in; views read `state`. Views never touch the network.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState = .needsLogin

    /// In-memory ring buffer of recent samples (Phase 2 sparkline). Not persisted.
    @Published private(set) var history: [Usage] = []
    private let historyCap = 60

    func setState(_ newState: UsageState) {
        state = newState
        if case .loaded(let usage) = newState {
            history.append(usage)
            if history.count > historyCap {
                history.removeFirst(history.count - historyCap)
            }
        }
    }

    /// Convenience accessor for the most recent successful sample.
    var latest: Usage? {
        if case .loaded(let usage) = state { return usage }
        return history.last
    }
}
