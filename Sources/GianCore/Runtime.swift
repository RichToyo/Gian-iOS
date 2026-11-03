import Foundation

@MainActor
public protocol GianClock: AnyObject {
    func now() -> Date
}

@MainActor
public final class SystemGianClock: GianClock {
    public init() {}
    public func now() -> Date { Date() }
}

@MainActor
public final class ManualGianClock: GianClock {
    public var instant: Date
    /// When non-zero, every read advances time like a real clock, so code that
    /// reads the clock twice and assumes equal values is caught in tests.
    public var advancesOnRead: TimeInterval = 0
    public init(instant: Date) { self.instant = instant }
    public func now() -> Date {
        defer { instant = instant.addingTimeInterval(advancesOnRead) }
        return instant
    }
}

@MainActor
public protocol GianIDGenerating: AnyObject {
    func next(at date: Date) -> String
}

@MainActor
public final class UUIDv7IDGenerator: GianIDGenerating {
    public init() {}
    public func next(at date: Date) -> String { UUIDv7.generate(date: date) }
}

/// Deterministic IDs for previews and tests. Each call is a distinct UUID v7.
@MainActor
public final class SequenceIDGenerator: GianIDGenerating {
    private var counter = 0
    public init() {}
    public func next(at date: Date) -> String {
        counter += 1
        return UUIDv7.generate(date: date, counter: counter)
    }
}

public enum UUIDv7 {
    public static func generate(date: Date, counter: Int? = nil) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        bytes[0] = UInt8((milliseconds >> 40) & 0xff)
        bytes[1] = UInt8((milliseconds >> 32) & 0xff)
        bytes[2] = UInt8((milliseconds >> 24) & 0xff)
        bytes[3] = UInt8((milliseconds >> 16) & 0xff)
        bytes[4] = UInt8((milliseconds >> 8) & 0xff)
        bytes[5] = UInt8(milliseconds & 0xff)
        if let counter {
            var value = counter
            for index in stride(from: 15, through: 6, by: -1) {
                bytes[index] = UInt8(value & 0xff)
                value >>= 8
            }
        } else {
            for index in 6..<16 {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let cuts = [8, 12, 16, 20]
        var parts: [String] = []
        var cursor = hex.startIndex
        for cut in cuts {
            let next = hex.index(hex.startIndex, offsetBy: cut)
            parts.append(String(hex[cursor..<next]))
            cursor = next
        }
        parts.append(String(hex[cursor...]))
        return parts.joined(separator: "-")
    }
}
