import Foundation

public struct SecretRedactor: Sendable {
    private let secrets: [String]

    public init(secrets: [String]) {
        self.secrets = secrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public func redact(_ value: String) -> String {
        var result = value
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "••••••")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != secret {
                result = result.replacingOccurrences(of: encoded, with: "••••••")
            }
        }

        let patterns = [
            #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#,
            #"(?i)(x-vibe-stick-token\s*:\s*)[^\s]+"#,
            #"(?i)((?:api[_-]?key|password|token)\s*[=:]\s*)[^\s,;]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1••••••",
                options: .regularExpression
            )
        }
        return result.unicodeScalars
            .filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
    }
}
