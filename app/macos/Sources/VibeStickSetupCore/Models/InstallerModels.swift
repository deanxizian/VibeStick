import Foundation

public struct SerialDevice: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let calloutPath: String
    public let name: String
    public let vendorID: Int?
    public let productID: Int?
    public let serialNumber: String?

    public init(
        id: UInt64,
        calloutPath: String,
        name: String,
        vendorID: Int? = nil,
        productID: Int? = nil,
        serialNumber: String? = nil
    ) {
        self.id = id
        self.calloutPath = calloutPath
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    public var isEspressifUSB: Bool { vendorID == 0x303A }

    public var detail: String {
        var parts = [calloutPath]
        if let vendorID, let productID {
            parts.append(String(format: "VID %04X · PID %04X", vendorID, productID))
        }
        return parts.joined(separator: " · ")
    }
}

public struct NetworkAddress: Identifiable, Hashable, Sendable {
    public var id: String { "\(interface):\(address)" }
    public let interface: String
    public let address: String

    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }
}

public struct Prerequisite: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case python
        case swift
        case espIDF
        case bridge
    }

    public let kind: Kind
    public let available: Bool
    public let detail: String
    public let path: String?

    public var id: String { kind.rawValue }

    public init(kind: Kind, available: Bool, detail: String, path: String? = nil) {
        self.kind = kind
        self.available = available
        self.detail = detail
        self.path = path
    }
}

public struct SystemSnapshot: Equatable, Sendable {
    public let networkAddresses: [NetworkAddress]
    public let serialDevices: [SerialDevice]
    public let prerequisites: [Prerequisite]
    public let idfExportPath: String?

    public init(
        networkAddresses: [NetworkAddress] = [],
        serialDevices: [SerialDevice] = [],
        prerequisites: [Prerequisite] = [],
        idfExportPath: String? = nil
    ) {
        self.networkAddresses = networkAddresses
        self.serialDevices = serialDevices
        self.prerequisites = prerequisites
        self.idfExportPath = idfExportPath
    }

    public static let empty = SystemSnapshot()
}

public enum DeploymentPhase: String, CaseIterable, Identifiable, Sendable {
    case saveConfiguration
    case buildFirmware
    case installBridge
    case flashFirmware
    case waitForDevice
    case verify

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .saveConfiguration: "保存配置"
        case .installBridge: "安装 Mac 服务"
        case .buildFirmware: "构建固件"
        case .flashFirmware: "烧录 StickS3"
        case .waitForDevice: "等待设备联网"
        case .verify: "运行诊断"
        }
    }
}

public enum StepState: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed(String)
}

public struct DeploymentStep: Identifiable, Equatable, Sendable {
    public let phase: DeploymentPhase
    public var state: StepState

    public var id: DeploymentPhase { phase }

    public init(phase: DeploymentPhase, state: StepState = .pending) {
        self.phase = phase
        self.state = state
    }
}

public struct CommandSpec: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let displayName: String

    public init(executable: URL, arguments: [String], workingDirectory: URL, displayName: String) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.displayName = displayName
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let outputWasTruncated: Bool
    public let output: String

    public init(exitCode: Int32, outputWasTruncated: Bool = false, output: String = "") {
        self.exitCode = exitCode
        self.outputWasTruncated = outputWasTruncated
        self.output = output
    }
}
