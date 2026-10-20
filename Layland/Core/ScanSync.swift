// What the scanning threads share: counters, flags and locked values. On macOS 15 and later,
// Swift's own Atomic and Mutex, which the scanner has always used; on macOS 14, which has
// neither, an unfair lock around each value (OSAllocatedUnfairLock, the same os_unfair_lock
// Mutex is built on, behind one more pointer).
//
// Chosen once, when a scanner is made (`make(legacy:)`). Either way a worker's call is one
// class method away from the Atomic or the lock, and the calls come once per directory, not
// per file (TreeBuilder commits a whole listing at a time), so the choice is invisible next to
// the directory reads themselves. `layland-bench --legacy-locks` times the macOS 14 path on a
// newer Mac, to keep it that way.

import Foundation
import os
import Synchronization

/// A count that many threads add to.
class ScanCounter: @unchecked Sendable {
    static func make(legacy: Bool) -> ScanCounter {
        if #available(macOS 15, *), !legacy { return AtomicCounter() }
        return LockedCounter()
    }

    func add(_ value: Int64) { fatalError("abstract") }
    func load() -> Int64 { fatalError("abstract") }
}

@available(macOS 15, *)
private final class AtomicCounter: ScanCounter, @unchecked Sendable {
    private let value = Atomic<Int64>(0)
    override func add(_ value: Int64) { self.value.wrappingAdd(value, ordering: .relaxed) }
    override func load() -> Int64 { value.load(ordering: .relaxed) }
}

private final class LockedCounter: ScanCounter, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Int64(0))
    override func add(_ value: Int64) { self.value.withLock { $0 &+= value } }
    override func load() -> Int64 { value.withLock { $0 } }
}

/// A flag that is set once: started, cancelled.
class ScanFlag: @unchecked Sendable {
    static func make(legacy: Bool) -> ScanFlag {
        if #available(macOS 15, *), !legacy { return AtomicFlag() }
        return LockedFlag()
    }

    var isSet: Bool { fatalError("abstract") }
    func set() { fatalError("abstract") }
    /// Sets the flag and says whether it was set already, as one step.
    func testAndSet() -> Bool { fatalError("abstract") }
}

@available(macOS 15, *)
private final class AtomicFlag: ScanFlag, @unchecked Sendable {
    private let value = Atomic<Bool>(false)
    override var isSet: Bool { value.load(ordering: .relaxed) }
    override func set() { value.store(true, ordering: .relaxed) }
    override func testAndSet() -> Bool { value.exchange(true, ordering: .acquiringAndReleasing) }
}

private final class LockedFlag: ScanFlag, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)
    override var isSet: Bool { value.withLock { $0 } }
    override func set() { value.withLock { $0 = true } }
    override func testAndSet() -> Bool { value.withLock { state in defer { state = true }; return state } }
}

/// A value only one thread at a time may touch.
class ScanLock<Value: Sendable>: @unchecked Sendable {
    static func make(_ value: Value, legacy: Bool) -> ScanLock<Value> {
        if #available(macOS 15, *), !legacy { return MutexLock(value) }
        return UnfairLock(value)
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result { fatalError("abstract") }
}

@available(macOS 15, *)
private final class MutexLock<Value: Sendable>: ScanLock<Value>, @unchecked Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    override func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

private final class UnfairLock<Value: Sendable>: ScanLock<Value>, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    override func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        lock.withLockUnchecked { body(&$0) }
    }
}
