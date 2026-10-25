import Foundation

/// What Paste last again (and Paste Here) pastes: the waiting text if there
/// is any, otherwise the newest thought's text as it was delivered (the
/// cleaned text when cleanup was used). A thrown-away thought is never
/// pasted again, and neither is anything older: when the newest thought was
/// thrown away, Paste last again pastes nothing.
public struct PasteAgain: Sendable {
    /// The newest thought that was pasted or held as waiting, and its text.
    public private(set) var lastDelivered: (id: Int64, text: String)?
    /// Rows thrown away in this run, in case the row read from the database
    /// is older than the throw-away.
    private var thrownAway: Set<Int64> = []

    public init() {}

    /// A thought's paste finished: pasted or waiting is remembered; stopped
    /// by Throw Away counts as thrown away.
    public mutating func delivered(id: Int64, text: String, outcome: PasteOutcome) {
        switch outcome {
        case .pasted, .waiting: lastDelivered = (id, text)
        case .stopped: thrownAway(id: id)
        }
    }

    /// The row was thrown away: before its paste, during it, or as waiting text.
    public mutating func thrownAway(id: Int64) {
        thrownAway.insert(id)
        if lastDelivered?.id == id { lastDelivered = nil }
    }

    /// What to paste again. `waiting`: the text the menu shows as waiting.
    /// `newest`: the newest row.
    public func text(waiting: (id: Int64, text: String)?, newest: ChunkSummary?) -> (id: Int64, text: String)? {
        if let waiting { return waiting }
        guard let newest, newest.status != "discarded", !thrownAway.contains(newest.id) else { return nil }
        if let lastDelivered, lastDelivered.id == newest.id { return lastDelivered }
        guard newest.status == "transcribed", let raw = newest.rawText, !raw.isEmpty else { return nil }
        return (newest.id, raw)
    }
}
