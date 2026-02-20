import AppKit
import SwiftUI

// CLI mode: `Rilmazafone build ...` or `Rilmazafone init ...`
// GUI mode: all other invocations launch the normal SwiftUI app.

if CommandLine.arguments.count >= 2 {
    let subcommand = CommandLine.arguments[1]

    switch subcommand {
    case "build":
        NSApplication.shared.setActivationPolicy(.prohibited)
        exit(CLIBuildRunner.run(arguments: Array(CommandLine.arguments.dropFirst(2))))

    case "init":
        NSApplication.shared.setActivationPolicy(.prohibited)
        exit(CLIBuildRunner.runInit(arguments: Array(CommandLine.arguments.dropFirst(2))))

    case "-h", "--help", "help":
        CLIBuildRunner.printGlobalHelp()
        exit(0)

    default:
        break
    }
}

RilmazafoneApp.main()
