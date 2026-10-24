#if os(macOS)
import Foundation
import Testing
@testable import QuagmireExtras

@Suite("Shell filter command")
struct ShellFilterCommandTests {
    @Test func pipesStdinThroughTheCommand() async throws {
        let output = try await ShellFilterCommand.run("sort", stdin: "pear\napple\n")
        #expect(output == "apple\npear\n")
    }

    @Test func failureReportsStderr() async {
        await #expect(throws: ShellFilterCommand.Failure.exited(status: 3, stderr: "nope")) {
            try await ShellFilterCommand.run("echo nope >&2; exit 3", stdin: "")
        }
    }

    @Test func commandThatIgnoresStdinStillFinishes() async throws {
        let big = String(repeating: "line\n", count: 200_000)
        let output = try await ShellFilterCommand.run("echo done", stdin: big)
        #expect(output == "done\n")
    }

    @Test func slowCommandTimesOut() async {
        await #expect(throws: ShellFilterCommand.Failure.timedOut(seconds: 1)) {
            try await ShellFilterCommand.run("sleep 5", stdin: "", timeoutSeconds: 1)
        }
    }
}
#endif
