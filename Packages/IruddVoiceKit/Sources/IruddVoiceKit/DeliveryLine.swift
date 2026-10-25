import Foundation

/// Delivers finished thoughts in the order they ended. Each thought's text
/// is made (recognised and cleaned) as soon as it ends, alongside any
/// earlier thought still being made, but it's pasted or held only after
/// every earlier thought has been. So a long thought followed by a short
/// one pastes the long one first.
///
/// Thoughts get rising numbers. Throw Away during cleanup marks the newest
/// thought still in flight whose delivery hasn't started; only that thought
/// is discarded, and only its own delivery clears the mark. A thought being
/// pasted can't be marked, so no mark is ever left behind.
@MainActor
public final class DeliveryLine<Item: Sendable> {
    private var nextNumber = 0
    /// Thoughts that ended and aren't delivered yet, oldest first.
    public private(set) var inFlight: [Int] = []
    private var thrownAway: Set<Int> = []
    /// Thoughts whose delivery (paste or hold) has started.
    private var delivering: Set<Int> = []
    private var last: Task<Void, Never>?
    /// Runs after each delivery with how many thoughts are still in flight.
    public var onDelivered: ((_ remaining: Int) -> Void)?

    public init() {}

    /// A thought is being made or waiting for an earlier one.
    public var isBusy: Bool { !inFlight.isEmpty }

    /// Adds a thought that just ended. `make` starts now, off the main
    /// actor; `deliver` runs on the main actor once `make` is done and every
    /// earlier thought is delivered. `thrownAway` says Throw Away marked it.
    @discardableResult
    public func add(make: @escaping @Sendable (_ number: Int) async -> Item,
                    deliver: @escaping @MainActor (_ number: Int, _ item: Item, _ thrownAway: Bool) async -> Void)
        -> Task<Void, Never>
    {
        nextNumber += 1
        let number = nextNumber
        inFlight.append(number)
        let made = Task.detached(priority: .userInitiated) { await make(number) }
        let previous = last
        let task = Task { @MainActor in
            let item = await made.value
            await previous?.value
            let discard = self.thrownAway.remove(number) != nil
            self.delivering.insert(number)
            await deliver(number, item, discard)
            self.delivering.remove(number)
            self.inFlight.removeAll { $0 == number }
            self.onDelivered?(self.inFlight.count)
        }
        last = task
        return task
    }

    /// Throw Away while thoughts are being made: marks the newest one whose
    /// delivery hasn't started. Returns its number, or nil when there's none
    /// (nothing in flight, or only a thought already being pasted).
    @discardableResult
    public func throwAwayNewest() -> Int? {
        guard let newest = inFlight.last, !delivering.contains(newest) else { return nil }
        thrownAway.insert(newest)
        return newest
    }

    /// Thoughts marked by Throw Away and not delivered yet.
    public var marked: Set<Int> { thrownAway }

    /// Whether Throw Away marked this thought (to skip cleaning it).
    public func isThrownAway(_ number: Int) -> Bool {
        thrownAway.contains(number)
    }
}

/// What Throw Away acts on, from what the menu shows.
public enum ThrowAwayTarget: Equatable, Sendable {
    /// End the thought being heard; it's saved but never pasted.
    case thoughtBeingHeard
    /// Drop the text the menu shows as waiting.
    case waitingText
    /// Keep the newest thought still being transcribed or cleaned from
    /// being pasted.
    case newestInFlight
    case nothing

    public static func pick(activity: AppStatus.Activity, hasWaitingText: Bool, deliveryBusy: Bool) -> ThrowAwayTarget {
        switch activity {
        case .hearing: .thoughtBeingHeard
        case .textWaiting: hasWaitingText ? .waitingText : (deliveryBusy ? .newestInFlight : .nothing)
        case .cleaningUp: deliveryBusy ? .newestInFlight : (hasWaitingText ? .waitingText : .nothing)
        case .idle: hasWaitingText ? .waitingText : (deliveryBusy ? .newestInFlight : .nothing)
        }
    }
}
