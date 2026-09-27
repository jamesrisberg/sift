import Foundation
import HUDKit

// `sift <command> [key=value ...]`: talks to Sift's MacHUD control socket.
//
//   sift hello
//   sift state
//   sift panel show id=browser
//   sift panel mode id=browser compact
//   sift action navigate path=~/Downloads
//   sift action send path=~/Downloads/a.pdf target=2
//   sift settings set collisionPolicy=skip
//   sift watch                 # print pushed events until interrupted
//   sift quit

let usage = """
usage: sift <command> [key=value ...]
  hello | state | help | quit
  panel show|hide|toggle id=browser
  panel frame id=browser x= y= w= h=
  panel mode id=browser full|compact|parked
  action navigate path=<folder>
  action reveal path=<file>
  action send path=<file>[,<file>...] target=<name or number>
  action drop paths=<path%20encoded|...>   what a MacHUD dock drop sends
  settings get [key=]  |  settings set key=value ...
  watch [events=state]   stream events (Ctrl-C to stop)

"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "ctl" { arguments.removeFirst() }
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

// `action navigate ...` is shorthand for `action name=navigate ...`.
if command == "action", arguments.count > 1, !arguments[1].contains("=") {
    arguments[1] = "name=\(arguments[1])"
}
// Expand a leading "~" in path-like values (shells leave `path=~/x` alone).
arguments = arguments.map { arg in
    guard let eq = arg.firstIndex(of: "="), arg[arg.index(after: eq)...].hasPrefix("~") else { return arg }
    let key = arg[..<eq], value = String(arg[arg.index(after: eq)...])
    let expanded = value.split(separator: ",").map { ($0 as NSString).expandingTildeInPath }.joined(separator: ",")
    return "\(key)=\(expanded)"
}

let path = HUDSocket.path(for: ProcessInfo.processInfo.environment["SIFT_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "sift")

if command == "watch" {
    let args = HUDSocketClient.parseArguments(Array(arguments.dropFirst()))
    do {
        _ = try HUDSocketClient(path: path).subscribe(
            events: args["events"].map { $0.split(separator: ",").map(String.init) },
            onEvent: { event in
                if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                }
            },
            onClose: { exit(0) }
        )
    } catch {
        FileHandle.standardError.write(Data("sift is not running (\(error))\n".utf8))
        exit(1)
    }
    dispatchMain()
}

exit(HUDSocketClient.runCLI(path: path, arguments: arguments, appName: "sift"))
