import Foundation
import XCTest
@testable import VibeStickSetupCore
@testable import VibeStickSetupPlatform

final class ASRConnectionTesterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ASRStubURLProtocol.state.reset()
    }

    override func tearDown() {
        ASRStubURLProtocol.state.reset()
        super.tearDown()
    }

    func testSuccessfulRequestUsesOpenAICompatibleMultipartShape() async throws {
        ASRStubURLProtocol.state.setResponse(statusCode: 200, body: Data("{}".utf8))
        let tester = ASRConnectionTester(session: makeSession())
        let apiKey = "asr-test-key"

        try await tester.test(configuration: configuration(), apiKey: apiKey)

        let request = try XCTUnwrap(ASRStubURLProtocol.state.capturedRequest())
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.authorization, "Bearer \(apiKey)")
        XCTAssertTrue(request.contentType.hasPrefix("multipart/form-data; boundary=VibeStick-"))
        XCTAssertTrue(request.body.containsUTF8("name=\"model\"\r\n\r\nwhisper-test-model\r\n"))
        XCTAssertTrue(request.body.containsUTF8("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(request.body.containsUTF8("filename=\"vibestick-test.wav\""))
        XCTAssertTrue(request.body.containsUTF8("Content-Type: audio/wav"))
        XCTAssertTrue(request.body.containsUTF8("RIFF"))
    }

    func testUnauthorizedResponseDoesNotExposeAPIKeyOrResponseBody() async throws {
        let apiKey = "never-leak-this-api-key"
        let sensitiveResponse = Data("{\"error\":\"\(apiKey)\"}".utf8)
        ASRStubURLProtocol.state.setResponse(statusCode: 401, body: sensitiveResponse)
        let tester = ASRConnectionTester(session: makeSession())

        do {
            try await tester.test(configuration: configuration(), apiKey: apiKey)
            XCTFail("expected the ASR test to reject an unauthorized response")
        } catch let error as ASRConnectionError {
            XCTAssertEqual(error, .httpStatus(401))
            let publicDescriptions = [
                error.localizedDescription,
                String(describing: error),
                String(reflecting: error),
            ]
            for description in publicDescriptions {
                XCTAssertFalse(description.contains(apiKey))
                XCTAssertFalse(description.contains("error"))
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let request = try XCTUnwrap(ASRStubURLProtocol.state.capturedRequest())
        XCTAssertEqual(request.authorization, "Bearer \(apiKey)")
    }

    func testCancelledURLRequestMapsToSetupCancellation() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledASRURLProtocol.self]
        let tester = ASRConnectionTester(session: URLSession(configuration: configuration))

        do {
            try await tester.test(configuration: self.configuration(), apiKey: "cancel-test-key")
            XCTFail("expected cancellation")
        } catch let error as SetupCoreError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func configuration() -> SetupConfiguration {
        SetupConfiguration(
            asrProvider: .custom,
            asrBaseURL: "https://asr.example.test/v1",
            asrModel: "whisper-test-model",
            asrLanguage: "zh"
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ASRStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct CapturedASRRequest: Sendable {
    let url: URL?
    let httpMethod: String?
    let authorization: String
    let contentType: String
    let body: Data
}

private final class ASRStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 500
    private var responseBody = Data()
    private var request: CapturedASRRequest?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        statusCode = 500
        responseBody = Data()
        request = nil
    }

    func setResponse(statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.statusCode = statusCode
        responseBody = body
    }

    func record(_ request: URLRequest, body: Data) -> (statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.request = CapturedASRRequest(
            url: request.url,
            httpMethod: request.httpMethod,
            authorization: request.value(forHTTPHeaderField: "Authorization") ?? "",
            contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "",
            body: body
        )
        return (statusCode, responseBody)
    }

    func capturedRequest() -> CapturedASRRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class ASRStubURLProtocol: URLProtocol {
    static let state = ASRStubState()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(from: request)
        let stub = Self.state.record(request, body: body)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class CancelledASRURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

private extension Data {
    func containsUTF8(_ value: String) -> Bool {
        range(of: Data(value.utf8)) != nil
    }
}
