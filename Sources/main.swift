import AppKit
import Foundation

let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--make-fixture" {
    do { try makeFixture(at: URL(fileURLWithPath: args[2]), choice: args.contains("--choice"), multiple: args.contains("--multi-letters") ? "letters" : args.contains("--multi-bullets") ? "bullets" : nil) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if args.count >= 3 && args[1] == "--solve-batch" {
    do {
        let answer = try Solver().solveBatch(images:args.dropFirst(2).map { URL(fileURLWithPath:$0) },instructions:"")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        print(String(data:try encoder.encode(answer),encoding:.utf8)!)
    } catch { fputs("\(error.localizedDescription)\n",stderr); exit(1) }
} else if args.count >= 3 && args[1] == "--solve" {
    do {
        let started = Date()
        let answer = try Solver().solve(image: URL(fileURLWithPath: args[2]), instructions: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try encoder.encode(answer), encoding: .utf8)!)
        fputs(String(format: "Elapsed: %.1f s\n", Date().timeIntervalSince(started)), stderr)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate; app.run()
    }
}
