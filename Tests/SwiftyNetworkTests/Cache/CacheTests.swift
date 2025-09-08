import Testing
@testable import SwiftyNetwork

@Test("Cache Key Creation")
func testCacheKeyCreation() {
    let simpleKey = CacheKey("test-key")
    #expect(simpleKey.rawValue == "test-key")
}
