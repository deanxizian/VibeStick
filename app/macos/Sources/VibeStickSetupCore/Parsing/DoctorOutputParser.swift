import Foundation

public enum DiagnosticLevel: String, Sendable {
    case pass = "PASS"
    case warning = "WARN"
    case failure = "FAIL"
    case info = "INFO"
}

public struct DiagnosticRecord: Identifiable, Equatable, Sendable {
    public let level: DiagnosticLevel
    public let message: String

    public var id: String { "\(level.rawValue):\(message)" }

    public init(level: DiagnosticLevel, message: String) {
        self.level = level
        self.message = message
    }
}

public enum DoctorOutputParser {
    public static func parse(_ output: String) -> [DiagnosticRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard let space = text.firstIndex(of: " "),
                  let level = DiagnosticLevel(rawValue: String(text[..<space])) else { return nil }
            return DiagnosticRecord(
                level: level,
                message: String(text[text.index(after: space)...])
            )
        }
    }
}
