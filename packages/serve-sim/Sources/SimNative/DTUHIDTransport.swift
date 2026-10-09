// The dtuhidd input transport, adapted from facebook/idb's FBSimulatorControl
// (SimulatorDTUHIDConnection.swift, SimulatorXPCConnection.swift, DTUHIDModels.swift),
// Copyright (c) Meta Platforms, Inc. and affiliates, MIT license.

import Foundation
import Darwin
import XPC

/// Xcode 27 (CoreSimulator 1155.4 and later) puts a HID daemon, `dtuhidd`, in the simulator. Once
/// anything connects to it — Device Hub does on every boot — the guest drops input sent the legacy
/// way (Indigo over `SimDeviceLegacyHIDClient`): the events arrive without error and do nothing.
/// This sends touches, keys and buttons to `dtuhidd` itself instead, as Device Hub does.
///
/// Messages are XPC dictionaries `{messageType, isBarrier, featureIdentifier, payload}` on a host
/// connection to the guest's digitizer service.
final class DTUHIDTransport: @unchecked Sendable {
    static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"
    /// The first CoreSimulator to ship `dtuhidd`.
    static let firstCoreSimulatorVersion = "1155.4"

    private let connection: xpc_connection_t
    private let queue = DispatchQueue(label: "dtuhid", qos: .userInteractive)
    private var contactActive = false
    private var twoFingerActive = false

    /// Whether the loaded CoreSimulator ships `dtuhidd`, read from the framework in this process: the
    /// Xcode installer overwrites it, so it can differ from the selected Xcode.
    static var supported: Bool {
        guard let simDevice = NSClassFromString("SimDevice"),
              let version = Bundle(for: simDevice).infoDictionary?["CFBundleVersion"] as? String
        else { return false }
        return version.compare(firstCoreSimulatorVersion, options: .numeric) != .orderedAscending
    }

    /// Connects to `device`'s digitizer service and proves a live `dtuhidd` answers. Retried: the
    /// daemon is demand-launched and can abort while the boot settles, after which launchd throttles
    /// its respawn and every send would be dropped without an error.
    static func connect(device: NSObject, attempts: Int = 5) async throws -> DTUHIDTransport {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let transport = DTUHIDTransport(connection: try lookup(device: device))
                do {
                    try await transport.confirmLiveness()
                    return transport
                } catch {
                    transport.disconnect()
                    throw error
                }
            } catch {
                lastError = error
                print("[hid] dtuhidd did not answer (attempt \(attempt) of \(attempts)): \(error.localizedDescription)")
                if attempt < attempts { try await Task.sleep(for: .seconds(4)) }
            }
        }
        throw lastError ?? Self.error("dtuhidd unreachable")
    }

    private init(connection: xpc_connection_t) {
        self.connection = connection
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_set_event_handler(connection) { event in
            if xpc_equal(event, XPC_ERROR_CONNECTION_INTERRUPTED) {
                print("[hid] dtuhidd connection was interrupted")
            }
        }
        xpc_connection_resume(connection)
    }

    func disconnect() {
        xpc_connection_cancel(connection)
    }

    // MARK: - Events

    /// One finger. `type` is serve-sim's begin / move / end; `x`, `y` are normalized 0...1 from the
    /// top left. `edge` is serve-sim's Indigo edge (left 1, top 2, bottom 3, right 4).
    func sendTouch(type: String, x: Double, y: Double, edge: UInt32) {
        guard let phase = Self.phase(type, active: &contactActive) else { return }
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(event, "pointOne", Self.point(x, y))
        xpc_dictionary_set_uint64(event, "eventType", phase)
        xpc_dictionary_set_uint64(event, "edge", UInt64(Self.edge(edge)))
        xpc_dictionary_set_uint64(event, "target", 0)
        send("IndigoDigitizerEvent", event)
    }

    func sendTwoFingerTouch(type: String, x1: Double, y1: Double, x2: Double, y2: Double) {
        guard let phase = Self.phase(type, active: &twoFingerActive) else { return }
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(event, "pointOne", Self.point(x1, y1))
        xpc_dictionary_set_value(event, "pointTwo", Self.point(x2, y2))
        xpc_dictionary_set_uint64(event, "eventType", phase)
        xpc_dictionary_set_uint64(event, "edge", 0)
        xpc_dictionary_set_uint64(event, "target", 0)
        send("IndigoDigitizerEvent", event)
    }

    /// A USB HID keyboard usage (page 0x07). `down` true for a press.
    func sendKey(usage: UInt32, down: Bool) {
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(event, "usageCode", UInt64(usage))
        xpc_dictionary_set_uint64(event, "state", down ? 1 : 2)
        send("IndigoKeyboardButtonEvent", event)
    }

    /// A hardware button by its HID (page, usage): power is Consumer 0x0C/0x30, Siri 0x0C/0xCF,
    /// volume 0x0C/0xE9 and 0x0C/0xEA.
    func sendButton(page: UInt32, usage: UInt32, down: Bool) {
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(event, "usagePage", UInt64(page))
        xpc_dictionary_set_uint64(event, "usageCode", UInt64(usage))
        xpc_dictionary_set_uint64(event, "state", down ? 1 : 2)
        send("IndigoButtonEvent", event)
    }

    // MARK: - Wire

    private func message(_ type: String, _ payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", barrier)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }

    private func send(_ type: String, _ payload: xpc_object_t) {
        xpc_connection_send_message(connection, message(type, payload))
    }

    /// A barrier the daemon must answer, carrying keyboard usage 0 ("no event") so the guest sees no
    /// keypress. An unanswered probe is the only sign of a daemon that cannot run: the lookup and
    /// every send succeed against one either way.
    private func confirmLiveness() async throws {
        let probe = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(probe, "usageCode", 0)
        xpc_dictionary_set_uint64(probe, "state", 2)
        let request = message("IndigoKeyboardButtonEvent", probe, barrier: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            queue.asyncAfter(deadline: .now() + 4) {
                once.run { continuation.resume(throwing: Self.error("dtuhidd did not answer within 4s")) }
            }
            xpc_connection_send_message_with_reply(connection, request, queue) { reply in
                once.run {
                    if xpc_get_type(reply) == XPC_TYPE_ERROR {
                        continuation.resume(throwing: Self.error("dtuhidd answered with an XPC error"))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        // Device open and dispatch after the peer activates.
        try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Mapping

    /// begin → start, move → position, end → end. A move with no contact down starts one.
    private static func phase(_ type: String, active: inout Bool) -> UInt64? {
        switch type {
        case "begin", "move":
            defer { active = true }
            return active ? 1 : 0
        case "end":
            active = false
            return 2
        default:
            return nil
        }
    }

    private static func point(_ x: Double, _ y: Double) -> xpc_object_t {
        let point = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", min(max(x, 0), 1))
        xpc_dictionary_set_double(point, "y", min(max(y, 0), 1))
        return point
    }

    /// serve-sim's Indigo edge numbers left 1 and top 2; dtuhidd's top 1 and left 2.
    private static func edge(_ indigo: UInt32) -> UInt32 {
        switch indigo {
        case 1: return 2
        case 2: return 1
        default: return indigo
        }
    }

    // MARK: - Connection

    private typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
    private typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
    private typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void
    private typealias LookupFunc = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t

    /// The service's port in the simulator's bootstrap namespace, made a host connection: wrapped in an
    /// endpoint by `xpc_endpoint_create_mach_port_4sim` and marked simulator-to-host, without which
    /// the service sees the peer but never a payload. Returned unresumed.
    private static func lookup(device: NSObject) throws -> xpc_connection_t {
        guard let handle = dlopen(nil, RTLD_NOW) else { throw error("XPC symbols unavailable") }
        defer { dlclose(handle) }
        guard let endpointPtr = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let connectionPtr = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let enablePtr = dlsym(handle, "xpc_connection_enable_sim2host_4sim")
        else { throw error("XPC simulator symbols unavailable") }
        let endpointFromPort = unsafeBitCast(endpointPtr, to: EndpointFromPort.self)
        let connectionFromEndpoint = unsafeBitCast(connectionPtr, to: ConnectionFromEndpoint.self)
        let enableSim2Host = unsafeBitCast(enablePtr, to: EnableSim2Host.self)

        let selector = NSSelectorFromString("lookup:error:")
        guard device.responds(to: selector),
              let imp = class_getMethodImplementation(object_getClass(device)!, selector)
        else { throw error("-[SimDevice lookup:error:] not found") }
        var lookupError: NSError?
        let port = unsafeBitCast(imp, to: LookupFunc.self)(device, selector, serviceName as NSString, &lookupError)
        guard port != MACH_PORT_NULL else {
            throw lookupError ?? error("\(serviceName) not found in the simulator")
        }
        // Both create functions return +1; the endpoint consumes the lookup's send right.
        guard let endpoint = endpointFromPort(port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
              let connection = connectionFromEndpoint(endpoint)?.takeRetainedValue() as? xpc_connection_t
        else { throw error("could not connect to \(serviceName)") }
        enableSim2Host(connection)
        return connection
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "DTUHIDTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Runs its block the first time only, from any thread.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
