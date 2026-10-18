import Foundation

/// A complete cycle, optionally starting with a language inferred for the first conversion.
/// Subsequent presses always visit the remaining layouts rather than undoing back and forth.
public struct LayoutCycle {
    public let layoutIDs: [String]

    public init(layoutIDs: [String], startingID: String? = nil, firstTargetID: String? = nil) {
        var unique: [String] = []
        for id in layoutIDs where !unique.contains(id) { unique.append(id) }
        var ordered: [String] = []
        if let startingID, unique.contains(startingID) { ordered.append(startingID) }
        if let firstTargetID, unique.contains(firstTargetID), !ordered.contains(firstTargetID) {
            ordered.append(firstTargetID)
        }
        self.layoutIDs = ordered + unique.filter { !ordered.contains($0) }
    }

    public func next(after currentID: String) -> String? {
        guard layoutIDs.count > 1 else { return nil }
        guard let index = layoutIDs.firstIndex(of: currentID) else { return layoutIDs.first }
        return layoutIDs[(index + 1) % layoutIDs.count]
    }
}
