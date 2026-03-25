import Foundation

/// JSON-RPC response from cmux
public struct CMUXResponse {
    public let ok: Bool
    public let result: [String: Any]?
    public let error: [String: Any]?

    init(data: [String: Any]) {
        self.ok = data["ok"] as? Bool ?? false
        self.result = data["result"] as? [String: Any]
        self.error = data["error"] as? [String: Any]
    }
}

/// Protocol for cmux socket communication — mockable for testing
/// Not Sendable: uses [String: Any] which is inherently non-Sendable.
/// This is fine — cmux-layout is a single-threaded CLI tool.
public protocol CMUXSocketClient {
    func call(method: String, params: [String: Any]) throws -> CMUXResponse
}

/// Live implementation using Unix domain socket
public final class LiveSocketClient: CMUXSocketClient {
    private let socketPath: String
    private var requestId = 0

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath
            ?? (NSHomeDirectory() + "/Library/Application Support/cmux/cmux.sock")
    }

    public func call(method: String, params: [String: Any]) throws -> CMUXResponse {
        requestId += 1

        let request: [String: Any] = [
            "method": method,
            "params": params,
            "id": requestId
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)

        // Connect to Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.connectionFailed("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.connectionFailed("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketError.connectionFailed("connect() failed: \(errno)")
        }

        // Send request
        _ = requestData.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress!, requestData.count, 0)
        }

        // Read response (loop until we get complete JSON)
        var responseData = Data()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 1)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = Darwin.recv(fd, buffer, 65536, 0)
            guard bytesRead > 0 else { break }
            responseData.append(buffer.assumingMemoryBound(to: UInt8.self), count: bytesRead)
            // Try to parse — if valid JSON, we're done
            if let _ = try? JSONSerialization.jsonObject(with: responseData) {
                break
            }
        }

        guard !responseData.isEmpty else {
            throw SocketError.readFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw SocketError.invalidResponse
        }

        return CMUXResponse(data: json)
    }
}

public enum SocketError: Error {
    case connectionFailed(String)
    case readFailed
    case invalidResponse
}
