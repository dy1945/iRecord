import XCTest
import Darwin
@testable import ControlProtocol

final class ControlProtocolTests: XCTestCase {
    func testExportSizeCapsRetinaWindowAndKeepsEvenDimensions() {
        XCTAssertEqual(RecordingExportPolicy.fittedSize(CGSize(width: 3350, height: 2158), maxEdge: 1920),
                       CGSize(width: 1920, height: 1236))
        XCTAssertEqual(RecordingExportPolicy.fittedSize(CGSize(width: 1281, height: 721), maxEdge: 1920),
                       CGSize(width: 1280, height: 720))
        XCTAssertEqual(RecordingExportPolicy.fittedSize(CGSize(width: 3350, height: 2158), maxEdge: 0),
                       CGSize(width: 3350, height: 2158))
    }

    func testCropInsetsParseAndRemoveBrowserChrome() {
        let insets = RecordingExportPolicy.CropInsets.parse("180,0,0,0")
        XCTAssertEqual(insets, .init(top: 180, right: 0, bottom: 0, left: 0))
        XCTAssertEqual(RecordingExportPolicy.cropRect(CGSize(width: 3350, height: 2158), insets: insets!),
                       CGRect(x: 0, y: 180, width: 3350, height: 1978))
        XCTAssertNil(RecordingExportPolicy.CropInsets.parse("180,0,0"))
        XCTAssertNil(RecordingExportPolicy.CropInsets.parse("-1,0,0,0"))
        XCTAssertNil(RecordingExportPolicy.cropRect(CGSize(width: 100, height: 100),
                                                     insets: .init(top: 100, right: 0, bottom: 0, left: 0)))
        XCTAssertEqual(RecordingExportPolicy.pixelInsets(
            from: .init(top: 87, right: 0, bottom: 0, left: 0),
            sourceSize: CGSize(width: 3350, height: 2158),
            windowSize: CGSize(width: 1675, height: 1079)),
            .init(top: 174, right: 0, bottom: 0, left: 0))
    }

    func testMultiChunkRequestAndReply() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let client = pair[0], server = pair[1]
        defer { close(client); close(server) }
        ControlSocket.configure(client); ControlSocket.configure(server)
        let done = expectation(description: "server reply")
        let longTitle = String(repeating: "中文窗口", count: 3000)
        DispatchQueue.global().async {
            do {
                let request = try ControlSocket.receive(ControlRequest.self, from: server)
                XCTAssertEqual(request.command, "windows list")
                XCTAssertEqual(request.options["search"], longTitle)
                try ControlSocket.send(ControlReply(values: ["title": longTitle]), to: server)
            } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        try ControlSocket.send(ControlRequest(command: "windows list", options: ["search": longTitle]), to: client)
        let response = try ControlSocket.receive(ControlReply.self, from: client)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.values["title"], longTitle)
        wait(for: [done], timeout: 5)
    }

    func testMalformedAndDisconnectedPeer() throws {
        for payload in ["{bad json}", ""] {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            _ = payload.withCString { Darwin.write(pair[0], $0, strlen($0)) }
            shutdown(pair[0], SHUT_WR)
            XCTAssertThrowsError(try ControlSocket.receive(ControlRequest.self, from: pair[1]))
            close(pair[0]); close(pair[1])
        }
    }
}
