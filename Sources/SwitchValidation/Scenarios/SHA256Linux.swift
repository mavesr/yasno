#if !canImport(CryptoKit)
import Foundation

/// CryptoKit is Apple-only. The scenario fingerprint must be the same SHA-256 on Linux,
/// so that a report from either system names the same test data.
public struct SHA256 {
    public init() {}
    public static func hash(data: Data) -> Digest { var h = SHA256(); h.update(data: data); return h.finalize() }
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    public struct Digest: Sequence {
        public let bytes: [UInt8]
        public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
    }

    public mutating func update(data: Data) {
        length &+= UInt64(data.count)
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 64 { block(buffer[offset..<offset + 64]); offset += 64 }
        buffer.removeFirst(offset)
    }

    private mutating func block(_ chunk: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let base = chunk.startIndex
        for i in 0..<16 {
            w[i] = UInt32(chunk[base + 4 * i]) << 24 | UInt32(chunk[base + 4 * i + 1]) << 16 |
                   UInt32(chunk[base + 4 * i + 2]) << 8 | UInt32(chunk[base + 4 * i + 3])
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    public func finalize() -> Digest {
        var copy = self
        let bits = length &* 8
        var tail = copy.buffer + [0x80]
        while tail.count % 64 != 56 { tail.append(0) }
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        var offset = 0
        while offset < tail.count { copy.block(tail[offset..<offset + 64]); offset += 64 }
        return Digest(bytes: copy.h.flatMap { v in (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (UInt32($0) * 8)) } })
    }
}
#endif
