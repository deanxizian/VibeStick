import XCTest
@testable import VibeStickSetupCore

final class DoctorOutputParserTests: XCTestCase {
    func testParsesOnlyStructuredDiagnosticLines() {
        let output = """
        INFO Starting checks
        noisy subprocess output
        PASS Bridge health endpoint
        WARN No serial device
        FAIL Missing token
        """

        XCTAssertEqual(
            DoctorOutputParser.parse(output),
            [
                DiagnosticRecord(level: .info, message: "Starting checks"),
                DiagnosticRecord(level: .pass, message: "Bridge health endpoint"),
                DiagnosticRecord(level: .warning, message: "No serial device"),
                DiagnosticRecord(level: .failure, message: "Missing token"),
            ]
        )
    }
}
