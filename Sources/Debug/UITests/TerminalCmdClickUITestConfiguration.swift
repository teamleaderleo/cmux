#if DEBUG
import Foundation

/// Captures the environment used to configure the terminal Cmd-click fixture.
struct TerminalCmdClickUITestConfiguration {
    let environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    var isEnabled: Bool { environment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] == "1" }

    func value(for key: String) -> String? {
        environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
