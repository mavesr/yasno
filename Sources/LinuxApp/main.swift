import Foundation
import YasnoLinux

// yasno                       start (the window opens; a second start shows the running copy)
// yasno --background          start without the window (login)
// yasno --version             print the version
// yasno --setup-permissions   as root (pkexec): keyboard access for the users at the seat
// yasno --remove-permissions  as root: take that access away again
// yasno --diagnose            print what Yasno sees on this desktop
let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print(YasnoVersion.current)
    exit(0)
}
if arguments.contains("--setup-permissions") { exit(Setup.installPermissions()) }
if arguments.contains("--remove-permissions") { exit(Setup.removePermissions()) }
if arguments.contains("--diagnose") { exit(Diagnose.run()) }
setvbuf(stdout, nil, _IOLBF, 0)
exit(App.run(arguments: arguments.filter { $0 == "--background" || $0 == arguments[0] }))
