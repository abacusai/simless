// SimlessAgent: the only Simless process with Full Disk Access.
//
// Its single job is copying a patch dylib that `simless` compiled into a render-host
// slot's sandbox container. A file the sandboxed host wrote itself would be
// quarantined, and dlopen of quarantined code blocks on a Gatekeeper prompt.
//
// Protocol: newline-delimited JSON on a Unix socket.
//   {"cmd":"ping"}
//   {"cmd":"place","src":"<~/Library/Caches/simless/...>.dylib","dst":"<slot container>/Data/tmp/<name>.dylib"}
//
// Everything else is refused. The agent only writes:
//   - .dylib files read from simless's cache directory,
//   - into ~/Library/Containers/<UUID>/Data/tmp/ with no symlinks on the path,
//   - when that container's metadata names a render-host slot (bundle id *.simlessN).
import Foundation
import Network

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = "\(home)/Library/Application Support/Simless"
let cacheDir = "\(home)/Library/Caches/simless/"
let socketPath = CommandLine.arguments.dropFirst().first ?? "\(supportDir)/agent.sock"

func noSymlinks(_ path: String) -> Bool {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
}

func checkSource(_ src: String) -> String? {
    let p = (src as NSString).standardizingPath
    guard p.hasPrefix(cacheDir), p.hasSuffix(".dylib"), noSymlinks(p) else {
        return "source must be a .dylib under \(cacheDir)"
    }
    return nil
}

/// Returns the owning slot bundle id, or an error.
func checkDestination(_ dst: String) -> (slot: String?, error: String?) {
    let p = (dst as NSString).standardizingPath
    let root = "\(home)/Library/Containers/"
    guard p.hasPrefix(root), p.hasSuffix(".dylib") else { return (nil, "destination must be a .dylib in a container") }
    let parts = p.dropFirst(root.count).split(separator: "/")
    guard parts.count == 4, UUID(uuidString: String(parts[0])) != nil, parts[1] == "Data", parts[2] == "tmp" else {
        return (nil, "destination must be <container UUID>/Data/tmp/<file>")
    }
    let tmpDir = (p as NSString).deletingLastPathComponent
    guard noSymlinks(tmpDir) else { return (nil, "symlink on destination path") }
    let meta = "\(root)\(parts[0])/.com.apple.containermanagerd.metadata.plist"
    guard let d = FileManager.default.contents(atPath: meta) else {
        return (nil, "cannot read container metadata: grant SimlessAgent Full Disk Access")
    }
    guard let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
          let id = plist["MCMMetadataIdentifier"] as? String,
          id.range(of: #"\.simless[0-9]+$"#, options: .regularExpression) != nil else {
        return (nil, "container does not belong to a Simless slot")
    }
    return (id, nil)
}

func handle(_ line: Data) -> [String: Any] {
    guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let cmd = req["cmd"] as? String else { return ["ok": false, "error": "bad request"] }
    switch cmd {
    case "ping":
        return ["ok": true, "pid": getpid()]
    case "place":
        guard let src = req["src"] as? String, let dst = req["dst"] as? String else {
            return ["ok": false, "error": "place needs src + dst"]
        }
        if let error = checkSource(src) { return ["ok": false, "error": error] }
        let (slot, error) = checkDestination(dst)
        guard let slot else { return ["ok": false, "error": error ?? "rejected"] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: src))
            // .atomic writes a temp file and renames it over the target, so a
            // symlink planted at the destination is replaced, never followed.
            try data.write(to: URL(fileURLWithPath: dst), options: .atomic)
            return ["ok": true, "bytes": data.count, "slot": slot]
        } catch {
            return ["ok": false, "error": "\(error.localizedDescription) [\((error as NSError).code)]"]
        }
    default:
        return ["ok": false, "error": "unknown cmd"]
    }
}

try? FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
unlink(socketPath)
let params = NWParameters.tcp
params.requiredLocalEndpoint = .unix(path: socketPath)
let listener = try NWListener(using: params)
listener.newConnectionHandler = { conn in
    conn.start(queue: .main)
    var buffer = Data()
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
            if let data { buffer.append(data) }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                var out = (try? JSONSerialization.data(withJSONObject: handle(Data(line)))) ?? Data()
                out.append(0x0A)
                conn.send(content: out, completion: .contentProcessed { _ in })
            }
            if done || err != nil { conn.cancel() } else { receive() }
        }
    }
    receive()
}
listener.start(queue: .main)
dispatchMain()
