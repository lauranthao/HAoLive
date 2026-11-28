// NetworkTypeMonitor.swift
// HAo Live — current network type (Wi-Fi vs cellular), so the
// room page can apply Pure Live's separate cellular default
// quality (preferResolutionCellular) instead of the Wi-Fi one.
// NWPathMonitor on iOS; the Linux parse stub reports Wi-Fi
// (not cellular) so the file still parses off-device.

import Foundation
#if canImport(Network)
import Network
#endif

/// Shared, process-wide. Started once at app launch; the room
/// view reads the current value when it opens a room.
final class NetworkTypeMonitor: @unchecked Sendable {
    static let shared = NetworkTypeMonitor()

    private let lock = NSLock()
    private var _isCellular = false
    var isCellular: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCellular
    }

    private var started = false
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    private init() {}

    func start() {
        #if canImport(Network)
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._isCellular = path.usesInterfaceType(.cellular)
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "live.network-type"))
        self.monitor = monitor
        #endif
    }
}
