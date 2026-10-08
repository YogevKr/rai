import Darwin
import Foundation
import XCTest
@testable import RaiCore

final class UnixSocketLineTests: XCTestCase {
    func testFragmentedNewlinePreservesBytesAcrossReads() async throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        let fragments = [Data("first ".utf8), Data("שלום".utf8), Data(" line".utf8), Data([10])]
        let writer = Task.detached {
            for fragment in fragments {
                try fixture.write(fragment)
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        XCTAssertEqual(try fixture.client.readLine(), Data("first שלום line".utf8))
        try await writer.value
    }

    func testCoalescedLinesAndFollowingFragmentRespectEachLineLimit() async throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        try fixture.write(Data("a\n\n12345\npar".utf8))
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 1), Data("a".utf8))
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 0), Data())
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 5), Data("12345".utf8))
        let writer = Task.detached {
            try await Task.sleep(for: .milliseconds(2))
            try fixture.write(Data("tial\nlast\n".utf8))
        }
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 7), Data("partial".utf8))
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 4), Data("last".utf8))
        try await writer.value
    }

    func testBufferedTerminatedOverflowCanBeReadWithLargerLimit() throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        try fixture.write(Data("ok\n123456\nafter\n".utf8))
        XCTAssertEqual(try fixture.client.readLine(), Data("ok".utf8))
        assertLineTooLong(limit: 5) { try fixture.client.readLine(maximumBytes: 5) }
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 6), Data("123456".utf8))
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 5), Data("after".utf8))
    }

    func testAppendingToBufferedTailDoesNotReuseOldDataIndices() async throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        let head = Data(repeating: UInt8(ascii: "a"), count: 123)
        let tail = Data(repeating: UInt8(ascii: "b"), count: 4_096)
        try fixture.write(head + Data([10]) + tail)
        XCTAssertEqual(try fixture.client.readLine(), head)
        let remainder = Data(repeating: UInt8(ascii: "c"), count: 65_536)
        let writer = Task.detached { try fixture.write(remainder + Data("\nlast\n".utf8)) }
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: tail.count + remainder.count), tail + remainder)
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 4), Data("last".utf8))
        try await writer.value
    }

    func testUnterminatedOverflowPreservesTheBufferForTheNextRead() throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        try fixture.write(Data("123456".utf8))
        assertLineTooLong(limit: 5) { try fixture.client.readLine(maximumBytes: 5) }
        try fixture.write(Data("\nnext\n".utf8))
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 6), Data("123456".utf8))
        XCTAssertEqual(try fixture.client.readLine(maximumBytes: 4), Data("next".utf8))
    }

    func testLargeUnterminatedOverflowKeepsTheExistingLimit() async throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        let limit = HerdrEndpointWire.maximumFrameBytes
        let writer = Task.detached {
            try fixture.write(Data(repeating: UInt8(ascii: "x"), count: limit + 1))
        }
        let start = ContinuousClock.now
        assertLineTooLong(limit: limit) { try fixture.client.readLine(maximumBytes: limit) }
        let elapsed = start.duration(to: .now)
        try await writer.value
        print("unix-line-overflow bytes=\(limit + 1) elapsed=\(elapsed)")
    }

    func testClosedSocketRejectsAnUnterminatedLine() throws {
        let fixture = try LineSocketFixture()
        defer { fixture.close() }
        try fixture.write(Data("partial".utf8))
        Darwin.shutdown(fixture.peer, SHUT_WR)
        XCTAssertThrowsError(try fixture.client.readLine()) { error in
            guard case UnixSocketError.closed = error else { return XCTFail("Wrong error: \(error)") }
        }
        fixture.client.close()
        XCTAssertThrowsError(try fixture.client.readLine()) { error in
            guard case UnixSocketError.closed = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    private func assertLineTooLong(limit: Int, read: () throws -> Data,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try read(), file: file, line: line) { error in
            guard case UnixSocketError.lineTooLong(let actual) = error else {
                return XCTFail("Wrong error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(actual, limit, file: file, line: line)
        }
    }
}

/// Two owned endpoints on a private temporary path. No Herdr process is used.
private final class LineSocketFixture: @unchecked Sendable {
    let client: UnixSocket
    let peer: Int32

    init() throws {
        let path = "/tmp/rai-line-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw UnixSocketError.systemCall("listen", errno) }
        client = try UnixSocket(path: path)
        peer = accept(listener, nil, nil)
        guard peer >= 0 else { client.close(); throw UnixSocketError.systemCall("accept", errno) }
        var flag: Int32 = 1
        guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            client.close(); Darwin.close(peer)
            throw UnixSocketError.systemCall("setsockopt", errno)
        }
    }

    func close() {
        client.close()
        Darwin.close(peer)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(peer, base.advanced(by: sent), raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw UnixSocketError.systemCall("write", errno) }
                sent += count
            }
        }
    }
}
