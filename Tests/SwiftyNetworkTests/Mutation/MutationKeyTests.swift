import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("MutationKey Tests")
struct MutationKeyTests {

    @Test("Explicit init and string literal init produce equal keys")
    func explicitAndLiteralInitAreEquivalent() {
        let explicit = MutationKey("like:video:42")
        let literal: MutationKey = "like:video:42"

        #expect(explicit == literal)
    }

    @Test("description returns the raw value")
    func descriptionReturnsRawValue() {
        let key = MutationKey("like:video:42")

        #expect(key.description == "like:video:42")
        #expect("\(key)" == "like:video:42")
    }

    @Test("Round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let key = MutationKey("like:video:42")

        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(MutationKey.self, from: data)

        #expect(decoded == key)
    }

    @Test("Distinct raw values are not equal and hash differently")
    func distinctKeysAreNotEqual() {
        let a: MutationKey = "like:video:42"
        let b: MutationKey = "like:video:43"

        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }
}
