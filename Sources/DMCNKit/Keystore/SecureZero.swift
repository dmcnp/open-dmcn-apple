import Foundation

/// Overwrites memory with zeros. A plain store just before the memory is freed is a dead store
/// the optimizer may drop, so this goes through the C calls that promise not to be dropped.
func secureZero(_ memory: UnsafeMutableRawBufferPointer) {
    guard let base = memory.baseAddress, !memory.isEmpty else { return }
    #if canImport(Darwin)
        _ = memset_s(base, memory.count, 0, memory.count)
    #else
        explicit_bzero(base, memory.count)
    #endif
}

/// Zeros a `Data` in place. Only this copy: one a caller made earlier is out of reach.
func secureZero(_ data: inout Data) {
    data.withUnsafeMutableBytes { secureZero($0) }
}
