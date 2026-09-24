import Darwin

/// Reads another process's command-line arguments with `KERN_PROCARGS2`.
///
/// Works for processes owned by the same user without any entitlement.
struct ProcessArgumentsReader: Sendable {
    /// The arguments of `processIdentifier`, including `argv[0]`.
    ///
    /// - Parameter processIdentifier: The process to inspect.
    /// - Returns: The arguments, or `nil` when the process is gone or not readable.
    func arguments(of processIdentifier: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Self.parse(Array(buffer.prefix(size)))
    }

    /// Parses a `KERN_PROCARGS2` buffer: `argc`, the executable path, NUL
    /// padding, then `argc` NUL-terminated arguments.
    static func parse(_ buffer: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return nil }
        let argc = buffer.prefix(countSize).withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argc > 0 else { return [] }
        var index = countSize
        // Skip the executable path, then the NUL padding after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
