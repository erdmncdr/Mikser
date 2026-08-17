//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation

// MARK: - Errors

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed: \(status) '\(status.fourCharCode)'"
    }
}

extension OSStatus {
    /// Core Audio error codes are mostly four-character codes ('!obj', 'nope', …).
    var fourCharCode: String {
        let value = UInt32(bitPattern: self)
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
              let text = String(bytes: bytes, encoding: .ascii) else {
            return String(self)
        }
        return text
    }
}

@discardableResult
func caTry(_ operation: String, _ body: () -> OSStatus) throws -> OSStatus {
    let status = body()
    guard status == noErr else {
        throw CoreAudioError(operation: operation, status: status)
    }
    return status
}

// MARK: - AudioObjectID conveniences

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func hasProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = Self.address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(self, &addr)
    }

    func isSettable(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = Self.address(selector, scope: scope, element: element)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func write<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: T
    ) throws {
        var addr = Self.address(selector, scope: scope, element: element)
        var value = value
        try caTry("AudioObjectSetPropertyData(\(selector.fourCharCode))") {
            AudioObjectSetPropertyData(
                self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value
            )
        }
    }

    /// Reads a single fixed-size value (UInt32, pid_t, AudioObjectID, ASBD, …).
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type = T.self
    ) throws -> T {
        var addr = Self.address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        try caTry("AudioObjectGetPropertyData(\(selector.fourCharCode))") {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, storage)
        }
        return storage.pointee
    }

    func readOptional<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type = T.self
    ) -> T? {
        try? read(selector, scope: scope, element: element, as: type)
    }

    /// Reads a variable-length array (device list, process list, …).
    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        of type: T.Type = T.self
    ) throws -> [T] {
        var addr = Self.address(selector, scope: scope, element: element)
        var size: UInt32 = 0
        try caTry("AudioObjectGetPropertyDataSize(\(selector.fourCharCode))") {
            AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
        }
        guard size > 0 else { return [] }

        let capacity = Int(size) / MemoryLayout<T>.stride
        let storage = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { storage.deallocate() }
        try caTry("AudioObjectGetPropertyData(\(selector.fourCharCode))") {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, storage)
        }
        // Swift.min: this is a UInt32 extension, so a bare `min` resolves to the
        // static `UInt32.min`.
        let count = Swift.min(capacity, Int(size) / MemoryLayout<T>.stride)
        return Array(UnsafeBufferPointer(start: storage, count: count))
    }

    /// Properties returning a CFString (+1 ownership, balanced by takeRetainedValue).
    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var addr = Self.address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try caTry("AudioObjectGetPropertyData(\(selector.fourCharCode))") {
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
            }
        }
        guard let value else {
            throw CoreAudioError(operation: "readString(\(selector.fourCharCode))",
                                 status: kAudioHardwareUnspecifiedError)
        }
        return value.takeRetainedValue() as String
    }

    func readStringOptional(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        try? readString(selector, scope: scope)
    }

    // MARK: Property listeners

    @discardableResult
    func addListener(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) -> ListenerToken? {
        var addr = Self.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(self, &addr, queue, block)
        guard status == noErr else { return nil }
        return ListenerToken(objectID: self, address: addr, queue: queue, block: block)
    }
}

/// Carries what is needed to remove a listener; cleans up automatically on deinit.
final class ListenerToken {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID, address: AudioObjectPropertyAddress,
         queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

extension AudioObjectPropertySelector {
    var fourCharCode: String { OSStatus(bitPattern: self).fourCharCode }
}
