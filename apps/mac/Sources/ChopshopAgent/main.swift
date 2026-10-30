import Darwin
import Foundation

// Lanzador del agente incrustado en Chopshop.app (`Contents/MacOS/chopshop-agent`).
//
// Es el `BundleProgram` del LaunchAgent que registra la app con SMAppService (`Contents/Library/LaunchAgents/chopshop-agent.plist`)
// y la CLI local que usa la app para emparejarse sola (`chopshop-agent pair create --json`). Un ejecutable firmado y fijo
// (en vez de un script) para que launchd, la firma y los permisos de macOS vean siempre la misma identidad.
//
// Hace `execv` del Python incrustado (`Contents/Resources/agent/python`, python-build-standalone fijado en
// release/python-runtime.version) con el paquete `chopshop` (`Contents/Resources/agent/chopshop`), en modo aislado (-I: sin
// PYTHONPATH ni site del usuario) y sin escribir bytecode (-B: el bundle firmado no se toca).
//
//   chopshop-agent --launchd      lo que corre launchd: `chopshop agent run`, salida a ~/Library/Logs/Chopshop/agent.log
//   chopshop-agent <args…>        `chopshop <args…>` (p. ej. `pair create --json`), salida normal

let args = Array(CommandLine.arguments.dropFirst())
let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let agentDir = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/agent")
let python = agentDir.appendingPathComponent("python/bin/python3").path
let entry = agentDir.appendingPathComponent("chopshop-agent.py").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("chopshop-agent: \(message)\n".utf8))
    exit(2)
}

guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: entry) else {
    fail("falta el runtime incrustado en \(agentDir.path) (build sin EMBED_AGENT)")
}

// launchd arranca con un PATH mínimo: el agente llama a `t3`, `gh` y `tailscale`, que suelen vivir en Homebrew o ~/.local/bin.
let home = NSHomeDirectory()
var path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
for p in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
          "/Applications/Tailscale.app/Contents/MacOS"] where !path.contains(p) {
    path.append(p)
}
setenv("PATH", path.joined(separator: ":"), 1)
setenv("CHOPSHOP_BUNDLED", "1", 1)

var forward = args
if args.first == "--launchd" {
    forward = ["agent", "run"]
    let logs = "\(home)/Library/Logs/Chopshop"
    try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
    let log = "\(logs)/agent.log"
    // Rotación mínima: con más de 5 MB el log pasa a agent.log.1 (uno solo)
    if let size = (try? FileManager.default.attributesOfItem(atPath: log))?[.size] as? Int, size > 5_000_000 {
        try? FileManager.default.removeItem(atPath: log + ".1")
        try? FileManager.default.moveItem(atPath: log, toPath: log + ".1")
    }
    let fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    if fd >= 0 {
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
}

let argv = [python, "-I", "-B", entry] + forward
var cargs = argv.map { strdup($0) } + [nil]
execv(python, &cargs)
fail("no pude ejecutar \(python): \(String(cString: strerror(errno)))")
