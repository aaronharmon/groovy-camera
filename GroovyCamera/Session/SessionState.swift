import Foundation

/// A numbered place in a record's shot list. The number also becomes the start of its filename.
struct Slot: Hashable, Comparable, Sendable {
    let number: Int

    static let sleeveFront = Slot(number: 1)
    static let sleeveBack = Slot(number: 2)
    static let lastSide = Slot(number: 8)
    static let firstExtra = Slot(number: 10)

    enum Kind: Equatable, Sendable {
        case sleeve, disc, gatefold, extra
    }

    var kind: Kind {
        switch number {
        case 1, 2: .sleeve
        case 3...8: .disc
        case 9: .gatefold
        default: .extra
        }
    }

    /// What goes in the viewfinder's label, such as "03 · Side A".
    var title: String {
        let label = switch number {
        case 1: "Sleeve front"
        case 2: "Sleeve back"
        case 3...8: "Side \(["A", "B", "C", "D", "E", "F"][number - 3])"
        case 9: "Gatefold"
        default: "Extra"
        }
        return String(format: "%02d · ", number) + label
    }

    static func < (first: Slot, second: Slot) -> Bool {
        first.number < second.number
    }
}

/// Which slot the next photo goes in. This is plain logic so it can be tested without a camera.
struct SessionState: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A slot picked by tapping its thumbnail, to retake it or to shoot one that was skipped.
        case slot(Slot)
        case extra
    }

    var shot: Set<Slot> = []
    var skipped: Set<Slot> = []
    var target: Target?

    /// Nil only when every slot in the running order has been shot or skipped.
    var currentSlot: Slot? {
        switch target {
        case .slot(let slot): slot
        case .extra: nextExtra
        case nil: nextInOrder
        }
    }

    /// Runs through the sleeve and the six sides. Gatefold is only ever chosen by hand.
    private var nextInOrder: Slot? {
        (Slot.sleeveFront.number...Slot.lastSide.number)
            .map(Slot.init(number:))
            .first { !shot.contains($0) && !skipped.contains($0) }
    }

    private var nextExtra: Slot {
        let highest = shot.map(\.number).max() ?? 0
        return Slot(number: max(highest + 1, Slot.firstExtra.number))
    }

    /// The sleeve is required, so only sides can be skipped, and only when they're next in order.
    var canSkip: Bool {
        guard target == nil, let current = currentSlot else { return false }
        return current.kind == .disc
    }

    var canFinish: Bool {
        shot.contains(.sleeveFront) && shot.contains(.sleeveBack)
    }

    mutating func skipCurrent() {
        guard canSkip, let current = currentSlot else { return }
        skipped.insert(current)
    }

    mutating func recordShot(in slot: Slot) {
        shot.insert(slot)
        skipped.remove(slot)
        target = nil
    }
}
