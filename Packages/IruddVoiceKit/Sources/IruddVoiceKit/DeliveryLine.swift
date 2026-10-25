import Foundation

/// Delivers finished thoughts in the order they ended. Each thought's text
/// is made (recognised and cleaned) as soon as it ends, alongside any
/// earlier thought still being made, but it's pasted or held only after
/// every earlier thought has been. So a long thought followed by a short
/// one pastes the long one first.
///
/// Thoughts get rising numbers. Throw Away marks the newest thought still in
/// flight; only that thought is discarded, and only its own delivery clears
/// the mark. A mark can still stop a paste that has started, up to the
/// moment right before ⌘V (`shouldStop`). After that the thought can't be
/// marked, and the mark goes when its delivery ends, so none is left behind.
@MainActor
public final class DeliveryLine<Item: Sendable> {
    private var nextNumber = 0
    /// Thoughts that ended and aren't delivered yet, oldest first.
    public private(set) var inFlight: [Int] = []
    private var thrownAway: Set<Int> = []
    /// Thoughts past the last point where Throw Away can stop them (⌘V).
    private var committed: Set<Int> = []
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
            await deliver(number, item, self.thrownAway.contains(number))
            self.thrownAway.remove(number)
            self.committed.remove(number)
            self.inFlight.removeAll { $0 == number }
            self.onDelivered?(self.inFlight.count)
        }
        last = task
        return task
    }

    /// Throw Away while thoughts are being made or pasted: marks the newest
    /// one. Returns its number, or nil when there's none (nothing in flight,
    /// or the newest is past ⌘V).
    @discardableResult
    public func throwAwayNewest() -> Int? {
        guard let newest = inFlight.last, !committed.contains(newest) else { return nil }
        thrownAway.insert(newest)
        return newest
    }

    /// Thoughts marked by Throw Away and not delivered yet.
    public var marked: Set<Int> { thrownAway }

    /// Whether Throw Away marked this thought (to skip cleaning it).
    public func isThrownAway(_ number: Int) -> Bool {
        thrownAway.contains(number)
    }

    /// For `Paster.paste`: whether Throw Away marked this thought. At
    /// `beforeKeystroke`, an unmarked thought is committed: it can't be
    /// marked any more, since ⌘V is next.
    public func shouldStop(_ number: Int, at stage: PasteStage) -> Bool {
        if thrownAway.contains(number) { return true }
        if stage == .beforeKeystroke { committed.insert(number) }
        return false
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

    /// Where Throw Away was pressed.
    public enum Source: Sendable, CaseIterable {
        /// The hotkey: acts on what the menu-bar icon shows.
        case hotkey
        /// The Throw Away button on the waiting text: always that text.
        case waitingRow
    }

    public static func pick(_ source: Source = .hotkey, activity: AppStatus.Activity, hasWaitingText: Bool,
                            deliveryBusy: Bool) -> ThrowAwayTarget {
        if source == .waitingRow { return hasWaitingText ? .waitingText : .nothing }
        return switch activity {
        case .hearing: .thoughtBeingHeard
        case .textWaiting: hasWaitingText ? .waitingText : (deliveryBusy ? .newestInFlight : .nothing)
        case .cleaningUp: deliveryBusy ? .newestInFlight : (hasWaitingText ? .waitingText : .nothing)
        case .idle: hasWaitingText ? .waitingText : (deliveryBusy ? .newestInFlight : .nothing)
        }
    }
}
