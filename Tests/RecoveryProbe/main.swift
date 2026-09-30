import Foundation
import RenamorphCore
import Darwin

if CommandLine.arguments.count == 3 {
    _ = setpgid(0, 0)
    let request = try JSONDecoder().decode(WorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    if request.action == "invalid-response" {
        let response = WorkerResponse(info: ContentInfo(format: .png, width: Int.max, height: Int.max, hasAlpha: false))
        try JSONEncoder().encode(response).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    }
    var child: pid_t = 0
    var arguments = [strdup("/bin/sleep"), strdup("30"), nil]
    defer { arguments.forEach { free($0) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    guard posix_spawn(&child, "/bin/sleep", nil, nil, &arguments, &environment) == 0 else { exit(1) }
    try "\(getpid()) \(child)".write(toFile: request.input, atomically: true, encoding: .utf8)
    while true { pause() }
}
guard CommandLine.arguments.count == 4 else { exit(64) }
let store = try StateStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
var state = try store.load()
let worker = WorkerClient(executable: URL(fileURLWithPath: CommandLine.arguments[2]))
var job = state.jobs[0]
let transaction = Transaction(store: store, worker: worker) { job in
    state.jobs = [job]
    try store.save(state)
}
transaction.fault = { point in
    if point == CommandLine.arguments[3] { kill(getpid(), SIGKILL) }
}
try transaction.prepare(&job, settings: state.settings, cancel: Cancellation())
try transaction.publish(&job, settings: state.settings, cancel: Cancellation())
