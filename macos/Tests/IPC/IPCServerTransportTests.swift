import AppKit
import Darwin
import Foundation
import Testing
@testable import Ghostty

/// The IPC socket itself: what one client does must not decide whether the
/// next one is served. Every `ghoztty +…` command, and every status and
/// banner hook in every pane, goes through this socket.
@Suite(.serialized)
struct IPCServerTransportTests {
    /// A unix socket path short enough for `sockaddr_un` (104 bytes), which
    /// `NSTemporaryDirectory()` is not.
    private func socketPath() -> String {
        "/tmp/gz-ipc-test-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                for i in 0..<bytes.count { dest[i] = bytes[i] }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func waitUntilListening(_ path: String) async -> Bool {
        for _ in 0..<100 {
            if let fd = connect(path) {
                Darwin.close(fd)
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Send one request and read its response, giving up after `timeout`.
    /// Blocking, so call it off the main thread: handlers answer from main.
    private func request(_ path: String, _ json: String, timeout: Int) -> [String: Any]? {
        guard let fd = connect(path) else { return nil }
        defer { Darwin.close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = Array(json.utf8)
        var length = UInt32(payload.count).bigEndian
        guard withUnsafeBytes(of: &length, { send(fd, $0.baseAddress!, 4, 0) }) == 4,
              send(fd, payload, payload.count, 0) == payload.count else { return nil }

        var header = [UInt8](repeating: 0, count: 4)
        guard recv(fd, &header, 4, MSG_WAITALL) == 4 else { return nil }
        let size = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        var body = [UInt8](repeating: 0, count: size)
        guard recv(fd, &body, size, MSG_WAITALL) == size else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }

    private func requestOffMain(_ path: String, _ json: String, timeout: Int) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.request(path, json, timeout: timeout))
            }
        }
    }

    /// A client that connects and then says nothing — a suspended CLI, a
    /// stray `nc -U` — used to hold the one queue every command ran on, so
    /// every later command hung behind it.
    @Test func aSilentClientDoesNotBlockTheNextCommand() async throws {
        let ghostty = try #require(await MainActor.run { (NSApp.delegate as? AppDelegate)?.ghostty })
        let path = socketPath()
        let server = IPCServer(ghostty: ghostty, socketPath: path)
        server.start()
        defer { server.stop() }
        try #require(await waitUntilListening(path), "the server never listened")

        // Connects, sends half a length header, and stays connected.
        let silent = try #require(connect(path))
        defer { Darwin.close(silent) }
        var half: [UInt8] = [0, 0]
        #expect(send(silent, &half, 2, 0) == 2)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let response = await requestOffMain(path, #"{"action":"list"}"#, timeout: 3)
        #expect(response?["success"] as? Bool == true, "a command behind a silent client got no answer")
    }

    /// Several of them at once still leave room for a real command.
    @Test func manySilentClientsDoNotBlockTheNextCommand() async throws {
        let ghostty = try #require(await MainActor.run { (NSApp.delegate as? AppDelegate)?.ghostty })
        let path = socketPath()
        let server = IPCServer(ghostty: ghostty, socketPath: path)
        server.start()
        defer { server.stop() }
        try #require(await waitUntilListening(path), "the server never listened")

        var silent: [Int32] = []
        defer { silent.forEach { Darwin.close($0) } }
        for _ in 0..<12 {
            if let fd = connect(path) { silent.append(fd) }
        }
        #expect(silent.count == 12, "the server refused connections it had room for")
        try? await Task.sleep(nanoseconds: 200_000_000)

        let response = await requestOffMain(path, #"{"action":"list"}"#, timeout: 3)
        #expect(response?["success"] as? Bool == true, "a command behind silent clients got no answer")
    }

    /// A silent client is let go rather than held forever: it gets an error
    /// once the server has waited long enough for its request.
    @Test func aSilentClientIsDroppedAfterTheReadTimeout() async throws {
        let ghostty = try #require(await MainActor.run { (NSApp.delegate as? AppDelegate)?.ghostty })
        let path = socketPath()
        let server = IPCServer(ghostty: ghostty, socketPath: path)
        server.start()
        defer { server.stop() }
        try #require(await waitUntilListening(path), "the server never listened")

        let silent = try #require(connect(path))
        defer { Darwin.close(silent) }
        let closed: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var tv = timeval(tv_sec: Int(IPCServer.clientIOTimeout) + 4, tv_usec: 0)
                setsockopt(silent, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                // The server answers "invalid message" and closes; either
                // way the read returns instead of timing out on our side.
                var buf = [UInt8](repeating: 0, count: 256)
                var sawEOF = false
                while true {
                    let n = recv(silent, &buf, buf.count, 0)
                    if n == 0 { sawEOF = true; break }
                    if n < 0 { break }
                }
                continuation.resume(returning: sawEOF)
            }
        }
        #expect(closed, "the server never let go of a silent client")
    }

    /// Stopping the server from the main thread returns even while a command
    /// is waiting on the main thread — the wait at quit that could deadlock.
    @Test func stoppingWhileACommandWaitsOnMainDoesNotHang() async throws {
        let ghostty = try #require(await MainActor.run { (NSApp.delegate as? AppDelegate)?.ghostty })
        let path = socketPath()
        let server = IPCServer(ghostty: ghostty, socketPath: path)
        server.start()
        try #require(await waitUntilListening(path), "the server never listened")

        let stopped: Bool = await MainActor.run {
            // Main is busy here, so the `list` sent now is parked waiting for
            // it when stop() runs.
            DispatchQueue.global().async { _ = self.request(path, #"{"action":"list"}"#, timeout: 5) }
            Thread.sleep(forTimeInterval: 0.3)
            let done = DispatchSemaphore(value: 0)
            let watchdog = DispatchWorkItem {
                if done.wait(timeout: .now() + 5) == .timedOut {
                    fatalError("IPCServer.stop() deadlocked against a command waiting on main")
                }
            }
            DispatchQueue.global().async(execute: watchdog)
            server.stop()
            done.signal()
            return true
        }
        #expect(stopped)
    }
}
