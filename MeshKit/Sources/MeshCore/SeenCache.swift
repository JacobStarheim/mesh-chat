import Foundation

/// Remembers the most recent packet IDs so each packet is handled and relayed once.
/// Fixed capacity: the oldest IDs are forgotten first.
struct SeenCache {
    private var ring: [Data?]
    private var members: Set<Data> = []
    private var next = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        ring = Array(repeating: nil, count: capacity)
    }

    func contains(_ id: Data) -> Bool {
        members.contains(id)
    }

    /// Returns false if the ID was already present.
    @discardableResult
    mutating func insert(_ id: Data) -> Bool {
        guard !members.contains(id) else { return false }
        if let evicted = ring[next] {
            members.remove(evicted)
        }
        ring[next] = id
        members.insert(id)
        next = (next + 1) % ring.count
        return true
    }
}
