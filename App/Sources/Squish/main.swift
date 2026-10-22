import CSquishCore
import Foundation

// Run as `squish` (the symlink Settings › Automation installs, or Homebrew's), this binary is
// the command-line tool; otherwise it's the app.
if CommandLine.arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "squish" {
    exit(squish_cli_main(CommandLine.argc, CommandLine.unsafeArgv))
}
SquishApp.main()
