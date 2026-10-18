import Foundation

/// Fixed-capacity FIFO. Appending past capacity overwrites the oldest element, so memory stays bounded.
public struct RingBuffer<Element>: Sequence {
    public let capacity: Int
    private var storage: ContiguousArray<Element> = []
    private var head = 0  // index of the oldest element once full

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count == capacity }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Oldest element.
    public var first: Element? { storage.isEmpty ? nil : storage[head % storage.count] }

    /// Newest element.
    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    /// Element at chronological position `index` (0 is oldest).
    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < storage.count, "RingBuffer index out of range")
        return storage[(head + index) % storage.count]
    }

    /// Elements oldest first.
    public var elements: [Element] { Array(self) }

    public func makeIterator() -> AnyIterator<Element> {
        var position = 0
        let snapshot = self
        return AnyIterator {
            guard position < snapshot.count else { return nil }
            defer { position += 1 }
            return snapshot[position]
        }
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
