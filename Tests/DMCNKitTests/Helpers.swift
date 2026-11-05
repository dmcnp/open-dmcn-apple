import Foundation
@testable import DMCNKit

func unhex(_ s: String) -> Data {
    guard let d = Data(hex: s) else { fatalError("bad hex in a test vector: \(s)") }
    return d
}

func fill(_ count: Int, _ byte: UInt8) -> Data { .filled(count, with: byte) }

/// `count` bytes counting up from `start`: the browser suite's fillPattern.
func pattern(_ count: Int, from start: UInt8) -> Data {
    Data((0..<count).map { start &+ UInt8(truncatingIfNeeded: $0) })
}
