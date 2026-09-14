import Foundation

/// The XPC surface the privileged daemon exposes. Deliberately a single boolean —
/// no paths, no arguments, nothing the caller can turn into arbitrary execution.
@objc public protocol LidHelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (String?) -> Void)
    func readSleepDisabled(reply: @escaping (Bool, String?) -> Void)
}

/// Client side of the connection to the privileged daemon.
///
/// The daemon itself is not built yet (it needs a Developer ID to register via
/// `SMAppService`), so this currently fails closed: every call reports the helper
/// as unavailable rather than silently doing nothing. `HelperLidSleepOverride`
/// turns that into an explicit "idle-sleep only" degrade in the UI.
public actor LidHelperClient {
    public static let shared = LidHelperClient()
    public static let machServiceName = "com.vishwam.Awake.LidHelper"

    private var connection: NSXPCConnection?

    public func setSleepDisabled(_ disabled: Bool) async throws {
        let proxy = try proxy()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            proxy.setSleepDisabled(disabled) { message in
                if let message { k.resume(throwing: LidSleepError.helperFailed(message)) }
                else { k.resume() }
            }
        }
    }

    public func readSleepDisabled() async throws -> Bool {
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { k in
            proxy.readSleepDisabled { value, message in
                if let message { k.resume(throwing: LidSleepError.helperFailed(message)) }
                else { k.resume(returning: value) }
            }
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func proxy() throws -> LidHelperProtocol {
        let connection = existingOrNewConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? LidHelperProtocol
        else {
            throw LidSleepError.helperUnavailable
        }
        return proxy
    }

    private func existingOrNewConnection() -> NSXPCConnection {
        if let connection { return connection }
        let new = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: LidHelperProtocol.self)
        new.invalidationHandler = { [weak self] in
            Task { await self?.clear() }
        }
        new.resume()
        connection = new
        return new
    }

    private func clear() { connection = nil }
}
