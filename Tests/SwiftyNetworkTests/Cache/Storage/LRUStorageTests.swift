import Testing

@testable import SwiftyNetwork

@Suite("LRUStorage Tests")
struct LRUStorageTests {
    @Test("Insertion order is recency order")
    func insertionOrderIsRecencyOrder() {
        var storage = LRUStorage<String, Int>()
        storage.setValue(1, forKey: "a")
        storage.setValue(2, forKey: "b")
        storage.setValue(3, forKey: "c")

        #expect(storage.keysByRecency == ["a", "b", "c"])
        #expect(storage.count == 3)
    }

    @Test("Reading a value marks it most recently used; peeking does not")
    func readTouchesPeekDoesNot() {
        var storage = LRUStorage<String, Int>()
        storage.setValue(1, forKey: "a")
        storage.setValue(2, forKey: "b")

        #expect(storage.peekValue(forKey: "a") == 1)
        #expect(storage.keysByRecency == ["a", "b"])

        let read = storage.value(forKey: "a")
        #expect(read == 1)
        #expect(storage.keysByRecency == ["b", "a"])
    }

    @Test("Replacing a value updates it and marks it most recently used")
    func replaceUpdatesValueAndRecency() {
        var storage = LRUStorage<String, Int>()
        storage.setValue(1, forKey: "a")
        storage.setValue(2, forKey: "b")
        storage.setValue(10, forKey: "a")

        #expect(storage.peekValue(forKey: "a") == 10)
        #expect(storage.keysByRecency == ["b", "a"])
        #expect(storage.count == 2)
    }

    @Test("removeLeastRecentlyUsed evicts from the head")
    func removeLeastRecentlyUsedEvictsHead() throws {
        var storage = LRUStorage<String, Int>()
        storage.setValue(1, forKey: "a")
        storage.setValue(2, forKey: "b")
        _ = storage.value(forKey: "a")

        let removed = storage.removeLeastRecentlyUsed()
        let evicted = try #require(removed)
        #expect(evicted.key == "b")
        #expect(evicted.value == 2)
        #expect(storage.keysByRecency == ["a"])
    }

    @Test("Removing from the middle keeps the list linked and reuses the slot")
    func removeFromMiddleAndReuseSlot() {
        var storage = LRUStorage<String, Int>()
        storage.setValue(1, forKey: "a")
        storage.setValue(2, forKey: "b")
        storage.setValue(3, forKey: "c")

        let removed = storage.removeValue(forKey: "b")
        let removedAgain = storage.removeValue(forKey: "b")
        #expect(removed == 2)
        #expect(removedAgain == nil)
        #expect(storage.keysByRecency == ["a", "c"])

        storage.setValue(4, forKey: "d")
        #expect(storage.keysByRecency == ["a", "c", "d"])
        #expect(storage.peekValue(forKey: "d") == 4)
    }

    @Test("removeAll(where:) removes only matching values")
    func removeAllWhere() {
        var storage = LRUStorage<String, Int>()
        for (index, key) in ["a", "b", "c", "d"].enumerated() {
            storage.setValue(index, forKey: key)
        }

        storage.removeAll { $0.isMultiple(of: 2) }

        #expect(storage.keysByRecency == ["b", "d"])
    }

    @Test("removeAll empties storage and it remains usable")
    func removeAllResets() {
        var storage = LRUStorage<String, Int>()
        storage.setValue(1, forKey: "a")
        storage.removeAll()

        let evictedKey = storage.removeLeastRecentlyUsed()?.key
        #expect(storage.count == 0)
        #expect(evictedKey == nil)

        storage.setValue(2, forKey: "b")
        #expect(storage.keysByRecency == ["b"])
    }
}
