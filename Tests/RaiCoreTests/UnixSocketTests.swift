import Darwin
import XCTest
@testable import RaiCore

final class UnixSocketTests: XCTestCase {
    private func socketPair() -> (UnixSocket, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (UnixSocket(adoptingDescriptor: fds[0]), fds[1])
    }

    func testReadAndWriteLinesRoundTripOverAdoptedDescriptor() throws {
        let (socket, peer) = socketPair()
        defer { socket.close(); close(peer) }

        try socket.writeLine(Data("hello".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(peer, &buffer, buffer.count)
        XCTAssertEqual(Array(buffer[0..<count]), Array("hello\n".utf8))

        Data("reply\npartial".utf8).withUnsafeBytes {
            _ = write(peer, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(try socket.readLine(), Data("reply".utf8))
    }

    /// Regression: close() used to free the descriptor NUMBER while a blocked
    /// read(2) was still using it, so a recycled fd could receive the stale
    /// syscall. The reader must be unblocked with `.closed`, never crash or
    /// read someone else's socket.
    func testCloseWhileReaderIsBlockedUnblocksWithClosed() {
        let (socket, peer) = socketPair()
        defer { close(peer) }

        let unblocked = expectation(description: "reader unblocked")
        Thread.detachNewThread {
            do {
                _ = try socket.readLine()
                XCTFail("expected readLine to throw after close()")
            } catch UnixSocketError.closed {
                // The regression's expected outcome.
            } catch {
                XCTFail("expected .closed, got \(error)")
            }
            unblocked.fulfill()
        }
        // Let the reader reach the blocking read before closing under it.
        Thread.sleep(forTimeInterval: 0.1)
        socket.close()
        wait(for: [unblocked], timeout: 2)
    }

    func testOverlongUnterminatedLineThrowsInsteadOfBufferingForever() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let socket = UnixSocket(adoptingDescriptor: fds[0], maxLineBytes: 1024)
        defer { socket.close(); close(fds[1]) }

        let junk = Data(repeating: 0x41, count: 4096)
        junk.withUnsafeBytes { _ = write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try socket.readLine()) { error in
            guard case UnixSocketError.lineTooLong = error else {
                return XCTFail("expected .lineTooLong, got \(error)")
            }
        }
    }

    /// Regression: a fix to the overshoot-detection ordering once made this
    /// throw instead of returning the first line — checking the cap before
    /// checking for a newline rejects a perfectly healthy burst just because
    /// OTHER, not-yet-delivered messages happen to be queued behind it.
    func testCompleteLineIsReturnedEvenWhenTrailingQueuedDataExceedsCap() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let socket = UnixSocket(adoptingDescriptor: fds[0], maxLineBytes: 64)
        defer { socket.close(); close(fds[1]) }

        // One short, valid, newline-terminated line, followed by unrelated
        // trailing bytes that alone push the buffer past the 64-byte cap.
        let burst = Data("first\n".utf8) + Data(repeating: 0x42, count: 128)
        burst.withUnsafeBytes { _ = write(fds[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(try socket.readLine(), Data("first".utf8))
    }

    func testReceiveTimeoutUnblocksARead() {
        let (socket, peer) = socketPair()
        defer { socket.close(); close(peer) }
        socket.setReceiveTimeout(0.2)
        let start = Date()
        XCTAssertThrowsError(try socket.readLine())
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
