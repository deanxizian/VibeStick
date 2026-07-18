import Foundation
import VibeStickSetupCore

public struct ASRConnectionTester: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.ephemeralSession()
    }

    public func test(
        configuration: SetupConfiguration,
        apiKey: String
    ) async throws {
        guard configuration.asrProvider != .disabled else { return }
        guard !apiKey.isEmpty else { throw SetupCoreError.missingSecret("API Key") }
        guard ConfigurationValidator.isValidASRURL(configuration.asrBaseURL),
              let baseURL = URL(string: configuration.asrBaseURL),
              !configuration.asrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SetupCoreError.malformedConfiguration("语音服务地址或模型无效")
        }

        let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
        let boundary = "VibeStick-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("VibeStickSetup/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = multipartBody(
            boundary: boundary,
            model: configuration.asrModel,
            language: configuration.asrLanguage
        )

        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            response = result.1
        } catch is CancellationError {
            throw SetupCoreError.cancelled
        } catch {
            let urlError = error as NSError
            if Task.isCancelled
                || (urlError.domain == NSURLErrorDomain && urlError.code == NSURLErrorCancelled) {
                throw SetupCoreError.cancelled
            }
            throw ASRConnectionError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ASRConnectionError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ASRConnectionError.httpStatus(http.statusCode)
        }
    }

    private func multipartBody(boundary: String, model: String, language: String) -> Data {
        var body = Data()
        appendField("model", value: model, boundary: boundary, to: &body)
        if !language.isEmpty {
            appendField("language", value: language, boundary: boundary, to: &body)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"vibestick-test.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(silentWAV())
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func appendField(_ name: String, value: String, boundary: String, to body: inout Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private func silentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let sampleCount: UInt32 = sampleRate
        let pcmBytes = sampleCount * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36) + pcmBytes, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(pcmBytes, to: &data)
        data.append(Data(repeating: 0, count: Int(pcmBytes)))
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

public enum ASRConnectionError: LocalizedError, Equatable {
    case network(String)
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case let .network(message):
            "无法连接语音服务：\(message)"
        case .invalidResponse:
            "语音服务返回了无效响应"
        case let .httpStatus(status):
            switch status {
            case 401, 403: "语音服务拒绝了 API Key（HTTP \(status)）"
            case 404: "语音服务地址或模型不存在（HTTP 404）"
            case 429: "语音服务额度不足或请求过于频繁（HTTP 429）"
            default: "语音服务测试失败（HTTP \(status)）"
            }
        }
    }
}
