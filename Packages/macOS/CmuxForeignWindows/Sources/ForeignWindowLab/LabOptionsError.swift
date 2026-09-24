/// Why the lab's command line could not be parsed.
enum LabOptionsError: Error {
    case helpRequested
    case missingValue(String)
    case unknownArgument(String)

    var message: String? {
        switch self {
        case .helpRequested: nil
        case .missingValue(let flag): "missing value for \(flag)"
        case .unknownArgument(let argument): "unknown argument \(argument)"
        }
    }
}
