// MARK: - LRU Storage

/// Dictionary-backed storage that tracks least-recently-used order in O(1).
///
/// Entries live in an array-backed doubly linked list (least recent at the
/// head, most recent at the tail) indexed by a dictionary, so lookups,
/// recency updates, insertions, removals, and eviction are all constant time.
/// Freed slots are reused to keep the array compact.
///
/// This is a plain value type with no synchronization; the owning actor
/// (for example ``InMemoryCache``) provides isolation.
struct LRUStorage<Key: Hashable, Value> {
    private struct Node {
        let key: Key
        var value: Value
        var previous: Int?
        var next: Int?
    }

    private var nodes: [Node?] = []
    private var indexByKey: [Key: Int] = [:]
    private var freeIndices: [Int] = []
    /// Least recently used entry.
    private var head: Int?
    /// Most recently used entry.
    private var tail: Int?

    /// The number of stored entries.
    var count: Int { indexByKey.count }

    /// Keys from least to most recently used. O(n); intended for diagnostics and tests.
    var keysByRecency: [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(count)
        var cursor = head
        while let index = cursor, let node = nodes[index] {
            keys.append(node.key)
            cursor = node.next
        }
        return keys
    }

    /// Returns the value for `key` and marks it most recently used.
    mutating func value(forKey key: Key) -> Value? {
        guard let index = indexByKey[key] else { return nil }
        moveToMostRecent(index)
        return nodes[index]?.value
    }

    /// Returns the value for `key` without changing recency.
    func peekValue(forKey key: Key) -> Value? {
        guard let index = indexByKey[key] else { return nil }
        return nodes[index]?.value
    }

    /// Inserts or replaces the value for `key` and marks it most recently used.
    mutating func setValue(_ value: Value, forKey key: Key) {
        if let index = indexByKey[key] {
            nodes[index]?.value = value
            moveToMostRecent(index)
            return
        }

        let node = Node(key: key, value: value, previous: nil, next: nil)
        let index: Int
        if let freeIndex = freeIndices.popLast() {
            nodes[freeIndex] = node
            index = freeIndex
        } else {
            nodes.append(node)
            index = nodes.count - 1
        }
        indexByKey[key] = index
        appendAsMostRecent(index)
    }

    /// Removes the value for `key`.
    ///
    /// - Returns: The removed value, or `nil` if `key` was absent.
    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let index = indexByKey.removeValue(forKey: key) else { return nil }
        unlink(index)
        let value = nodes[index]?.value
        nodes[index] = nil
        freeIndices.append(index)
        return value
    }

    /// Removes and returns the least recently used entry, if any.
    @discardableResult
    mutating func removeLeastRecentlyUsed() -> (key: Key, value: Value)? {
        guard let head, let key = nodes[head]?.key, let value = removeValue(forKey: key) else {
            return nil
        }
        return (key, value)
    }

    /// Removes every entry whose value satisfies `shouldRemove`. O(n).
    mutating func removeAll(where shouldRemove: (Value) -> Bool) {
        var keysToRemove: [Key] = []
        for (key, index) in indexByKey {
            if let node = nodes[index], shouldRemove(node.value) {
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            removeValue(forKey: key)
        }
    }

    /// Removes every entry.
    mutating func removeAll() {
        nodes.removeAll()
        indexByKey.removeAll()
        freeIndices.removeAll()
        head = nil
        tail = nil
    }

    // MARK: - Linked List

    private mutating func moveToMostRecent(_ index: Int) {
        guard tail != index else { return }
        unlink(index)
        appendAsMostRecent(index)
    }

    private mutating func appendAsMostRecent(_ index: Int) {
        nodes[index]?.previous = tail
        nodes[index]?.next = nil
        if let tail {
            nodes[tail]?.next = index
        } else {
            head = index
        }
        tail = index
    }

    private mutating func unlink(_ index: Int) {
        guard let node = nodes[index] else { return }
        if let previous = node.previous {
            nodes[previous]?.next = node.next
        } else {
            head = node.next
        }
        if let next = node.next {
            nodes[next]?.previous = node.previous
        } else {
            tail = node.previous
        }
        nodes[index]?.previous = nil
        nodes[index]?.next = nil
    }
}
