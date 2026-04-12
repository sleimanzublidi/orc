import Models

// MARK: - ResolvableConvertible Conformances

// These conformances live in Template (not Models) because conversion
// failures throw `TemplateError.invalidConversion`, which is defined here.

extension String: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> String {
        string
    }
}

extension Int: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> Int {
        guard let value = Int(string) else {
            throw TemplateError.invalidConversion(
                value: string,
                targetType: "Int"
            )
        }
        return value
    }
}

extension Bool: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> Bool {
        switch string.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default:
            throw TemplateError.invalidConversion(
                value: string,
                targetType: "Bool"
            )
        }
    }
}

extension FailureStrategy: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> FailureStrategy {
        guard let value = FailureStrategy(rawValue: string) else {
            throw TemplateError.invalidConversion(
                value: string,
                targetType: "FailureStrategy"
            )
        }
        return value
    }
}

extension WorkspaceMode: ResolvableConvertible {
    public static func fromResolved(_ string: String) throws -> WorkspaceMode {
        guard let value = WorkspaceMode(rawValue: string) else {
            throw TemplateError.invalidConversion(
                value: string,
                targetType: "WorkspaceMode"
            )
        }
        return value
    }
}

