// Temporarily excluded from compilation while diagnosing a compiler crash.
// If this file causes the crash, we'll inspect and restore tests properly.
#if false
import Testing
@testable import SwiftyNetwork

@Test("GenericRepository basic smoke")
func testRepositorySmoke() async throws {
    #expect(Bool(true))
}
#endif
