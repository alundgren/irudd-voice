/// Permissions the app asks for during first-run setup.
public enum Permission: String, CaseIterable, Sendable {
    case microphone
    case speechRecognition
    case accessibility
    case clipboard

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .accessibility: "Accessibility"
        case .clipboard: "Clipboard"
        }
    }

    public var reason: String {
        switch self {
        case .microphone: "To hear you through the mic you pick."
        case .speechRecognition: "To turn your voice into text on this Mac."
        case .accessibility: "To paste the text where your cursor is."
        case .clipboard: "To put back what was on your clipboard after pasting."
        }
    }

    /// Without these the app can't dictate at all. Clipboard access only
    /// lets the app restore your clipboard after a paste.
    public var isRequired: Bool {
        self != .clipboard
    }
}

public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    case notAsked
}

/// What first-run setup still needs.
public struct SetupChecklist: Sendable, Equatable {
    public var permissions: [Permission: PermissionState]

    public init(permissions: [Permission: PermissionState]) {
        self.permissions = permissions
    }

    public func state(of permission: Permission) -> PermissionState {
        permissions[permission] ?? .notAsked
    }

    /// Required permissions that aren't granted yet, in the order setup shows them.
    public var missingRequired: [Permission] {
        Permission.allCases.filter { $0.isRequired && state(of: $0) != .granted }
    }

    public var canFinish: Bool {
        missingRequired.isEmpty
    }
}
