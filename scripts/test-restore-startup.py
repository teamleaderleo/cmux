"""Exercise the production self-deleting restore launcher without an app test host."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
out = root / '.glaeda/sidebar-lab/restore-startup-check'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'Sources/RestorableAgentSession.swift').read_text()
quoting = source.split('enum TerminalStartupShellQuoting {', 1)[1].split('/// Which syntax family', 1)[0]
launcher = (root / 'Sources/OneShotTerminalLauncherStore.swift').read_text()
runner = r'''
@main struct RestoreStartupCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let script = OneShotTerminalLauncherStore(temporaryDirectory: root).writeLauncherScript(
            command: "printf '%s\\n' RESTORE_ONCE", workingDirectory: root.path,
            execution: .resumeLoginShell)!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = "/bin/zsh"
        environment["ZDOTDIR"] = root.path
        process.environment = environment
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        precondition(text.components(separatedBy: "RESTORE_ONCE").count == 2)
        precondition(!text.contains("printf"))
        precondition(!FileManager.default.fileExists(atPath: script.path))
        print("PASS restore runs once without command echo, returns to shell, deletes its launcher")
    }
}
'''
path = out / 'Check.swift'
path.write_text('import Foundation\nenum TerminalStartupShellQuoting {' + quoting + launcher + runner)
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path), '-o', str(out/'check')], check=True)
subprocess.run([str(out/'check'), str(out)], check=True, timeout=15)
