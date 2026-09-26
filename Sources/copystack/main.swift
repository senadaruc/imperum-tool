import CopyStackKit
import Foundation

let arguments = CommandLine.arguments

func printUsage() {
    print("""
    copystack is the terminal picker for Imperum Tool's clipboard history. \
    It lets you browse, search, and re-paste items from your clipboard stack \
    without leaving the terminal. Run with --version to print the current \
    version, or --help to show this message.
    """)
}

if arguments.contains("--version") {
    print("copystack \(CopyStackKit.version)")
    exit(0)
} else if arguments.contains("--help") {
    printUsage()
    exit(0)
} else {
    FileHandle.standardError.write("copystack: not implemented yet\n".data(using: .utf8)!)
    exit(1)
}
