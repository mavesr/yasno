import Foundation

/// Physical key positions of an ISO Mac keyboard by virtual key code. A slip to the
/// next key is the same finger motion in every layout, so typos are generated here,
/// below the layout, and rendered by whichever layout happens to be active. The
/// spelling corrector uses the same geometry to weigh which slip is likelier.
public enum KeyboardGeometry {
    private static let rows: [(offset: Double, keys: [UInt16])] = [
        (0, [10, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]), // § 1 2 3 4 5 6 7 8 9 0 - =
        (1.5, [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]),   // q w e r t y u i o p [ ]
        (1.75, [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 42]),         // a s d f g h j k l ; ' \
        (1.25, [50, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44]),           // ` z x c v b n m , . /
    ]

    private static let positions: [UInt16: (row: Int, x: Double)] = {
        var result: [UInt16: (row: Int, x: Double)] = [:]
        for (row, line) in rows.enumerated() {
            for (i, key) in line.keys.enumerated() { result[key] = (row, line.offset + Double(i)) }
        }
        return result
    }()

    public static let neighbours: [UInt16: [UInt16]] = {
        var result: [UInt16: [UInt16]] = [:]
        for (key, a) in positions {
            result[key] = positions.filter {
                $0.key != key && abs(a.row - $0.value.row) <= 1 && abs(a.x - $0.value.x) <= 1.0001
            }.keys.sorted()
        }
        return result
    }()
}

extension KeyboardGeometry {
    public static func areNeighbours(_ a: UInt16, _ b: UInt16) -> Bool {
        neighbours[a]?.contains(b) == true
    }
}
