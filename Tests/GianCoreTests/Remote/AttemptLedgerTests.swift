import Foundation
import Testing
@testable import GianCore

/// The vault's attempt ledgers used to refuse every command once they held
/// 2048 IDs (a lifetime count: nothing ever removed an entry).
struct AttemptLedgerTests {
    private func id(_ seconds: Double) -> String { UUIDv7.generate(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds)) }

    @Test func aFullLedgerForgetsItsOldestQuarterInsteadOfRefusing() {
        var ledger: [String: String] = [:]
        var keys: [String] = []
        for index in 0..<AttemptLedger.capacity {
            let key = id(Double(index))
            keys.append(key)
            ledger[key] = "fingerprint"
        }
        let next = id(Double(AttemptLedger.capacity))
        AttemptLedger.makeRoom(&ledger, for: next)
        ledger[next] = "fingerprint"

        #expect(ledger.count == AttemptLedger.capacity * 3 / 4 + 1)
        #expect(ledger[keys[0]] == nil)
        #expect(ledger[keys[AttemptLedger.capacity / 4 - 1]] == nil)
        #expect(ledger[keys[AttemptLedger.capacity / 4]] != nil)
        #expect(ledger[keys.last!] != nil)
    }

    @Test func aKnownKeyOrARoomyLedgerIsLeftAlone() {
        var ledger = [id(1): "a", id(2): "b"]
        AttemptLedger.makeRoom(&ledger, for: id(3))
        #expect(ledger.count == 2)
        var full: [String: String] = [:]
        for index in 0..<AttemptLedger.capacity { full[id(Double(index))] = "f" }
        AttemptLedger.makeRoom(&full, for: full.keys.first!)
        #expect(full.count == AttemptLedger.capacity)
    }

    @Test func translationKeysAreOrderedByTheirRequestID() {
        #expect(AttemptLedger.stamp("host-1:\(id(10))") < AttemptLedger.stamp("host-1:\(id(20))"))
        #expect(AttemptLedger.stamp("not-an-id") == 0)
    }
}
