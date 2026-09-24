import Foundation

/// Command-line options for the lab.
struct LabOptions {
    static let usage = """
        usage: ForeignWindowLab [--profiles a,b] [--profiles-root DIR] [--diagnose [--json]] [--no-claim] [--verbose]

          --profiles a,b       Claude Desktop profile per pane, left to right (default: default,lab).
                               Names are normalized the way cmux panes normalize them.
          --profiles-root DIR  Profile root (default: cmux's, ~/Library/Application Support/cmux/external-apps/claude).
          --diagnose           Print Accessibility trust, the claude:// handler, and running Claude
                               instances with their owners, then exit. Opens no window, launches nothing.
          --json               With --diagnose, print JSON.
          --no-claim           When run from ForeignWindowLab.app, do not claim the claude:// handler.
                               (An unbundled run never claims it.)
          --verbose            Log foreign-window diagnostics to stderr.
        """

    var profiles: [String] = ["default", "lab"]
    var profilesRoot: URL?
    var diagnose = false
    var json = false
    var verbose = false
    var noClaim = false

    /// Parses `arguments` (without `argv[0]`).
    ///
    /// - Throws: ``LabOptionsError`` for unknown flags or missing values.
    init(arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--profiles":
                guard let value = iterator.next() else { throw LabOptionsError.missingValue(argument) }
                let names = value.split(separator: ",").map { String($0) }
                guard !names.isEmpty else { throw LabOptionsError.missingValue(argument) }
                profiles = names
            case "--profiles-root":
                guard let value = iterator.next() else { throw LabOptionsError.missingValue(argument) }
                profilesRoot = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            case "--diagnose":
                diagnose = true
            case "--json":
                json = true
            case "--verbose":
                verbose = true
            case "--no-claim":
                noClaim = true
            case "-h", "--help":
                throw LabOptionsError.helpRequested
            default:
                throw LabOptionsError.unknownArgument(argument)
            }
        }
    }
}
