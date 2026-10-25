import Foundation

/// What Paste last again (and Paste Here) pastes: the waiting text if there
/// is any, otherwise the newest thought's text as it was delivered (the
/// cleaned text when cleanup was used). A thrown-away thought is never
/// pasted again, and neither is anything older: when the newest thought was
/// thrown away, Paste last again pastes nothing. The same goes for a thought
/// still being transcribed, cleaned or pasted: nothing until it's delivered,
/// so its raw text never goes out ahead of (or as well as) its cleaned text.
public struct PasteAgain: Sendable {
    /// The newest thought that was pasted or held as waiting, and its text.
    public private(set) var lastDelivered: (id: Int64, text: String)?
    /// Rows thrown away in this run, in case the row read from the database
    /// is older than the throw-away.
    private var thrownAway: Set<Int64> = []
    /// Rows saved in this run and not delivered or thrown away yet.
    private var inFlight: Set<Int64> = []

    public init() {}

    /// A thought's row was saved: it's in flight until it's delivered or
    /// thrown away.
    public mutating func started(id: Int64) {
        inFlight.insert(id)
    }

    /// A thought's paste finished: pasted or waiting is remembered; stopped
    /// by Throw Away counts as thrown away.
    public mutating func delivered(id: Int64, text: String, outcome: PasteOutcome) {
        inFlight.remove(id)
        switch outcome {
        case .pasted, .waiting: lastDelivered = (id, text)
        case .stopped: thrownAway(id: id)
        }
    }

    /// The row was thrown away: before its paste, during it, or as waiting text.
    public mutating func thrownAway(id: Int64) {
        inFlight.remove(id)
        thrownAway.insert(id)
        if lastDelivered?.id == id { lastDelivered = nil }
    }

    /// What to paste again. `waiting`: the text the menu shows as waiting.
    /// `newest`: the newest row.
    public func text(waiting: (id: Int64, text: String)?, newest: ChunkSummary?) -> (id: Int64, text: String)? {
        if let waiting { return waiting }
        guard let newest, newest.status != "discarded", !thrownAway.contains(newest.id),
              !inFlight.contains(newest.id) else { return nil }
        if let lastDelivered, lastDelivered.id == newest.id { return lastDelivered }
        // A row from before this run (saved, then the app quit or restarted):
        // what was pasted, else the cleaned text, else the raw text.
        guard newest.status == "transcribed" else { return nil }
        let text = [newest.pastedText, newest.cleanedText, newest.rawText].lazy
            .compactMap { $0 }.first { !$0.isEmpty }
        return text.map { (newest.id, $0) }
    }

    /// Paste here waits for the panel to close before it pastes. Asked again
    /// after that wait: what to paste if thought `id` is still what Paste last
    /// again would paste, nil if it was thrown away (or replaced) meanwhile.
    public func recheck(id: Int64, waiting: (id: Int64, text: String)?, newest: ChunkSummary?) -> (id: Int64, text: String)? {
        guard let now = text(waiting: waiting, newest: newest), now.id == id else { return nil }
        return now
    }
}
