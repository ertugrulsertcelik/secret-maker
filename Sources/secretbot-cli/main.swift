import Foundation
import SecretBotCore

// Test aracı. Ayarları Secret Bot uygulamasıyla aynı yerden okur. Hiçbir zaman gerçek değişiklik yapmaz.
//   secretbot-cli --mask <mail.txt>          yapay zekâya gidecek maskeli metni göster
//   secretbot-cli --read <mail.txt>          maili ayarlardaki yapay zekâ ile oku (değerler gizli yazılır)
//   secretbot-cli <mail.txt> [context]       oku + sunucuda kontrol + dry-run

let args = CommandLine.arguments
let defaults = UserDefaults(suiteName: AppConfig.bundleID) ?? .standard
let cfg = AppConfig.load(defaults)

func usage() -> Never {
    print("""
    kullanım:
      secretbot-cli --mask <mail.txt>
      secretbot-cli --read <mail.txt>
      secretbot-cli <mail.txt> [context]
    """)
    exit(1)
}

func readFile(_ path: String) -> String {
    guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { print("Dosya okunamadı: \(path)"); exit(1) }
    return t
}

func describe(_ e: KeyEntry) -> String {
    let v = e.value.isEmpty ? "YOK" : "\(e.value.count) karakter, sha=\(sha256Hex(e.value).prefix(12))"
    return "  \(e.secretName) / \(e.key)  env=\(e.envName.isEmpty ? "-" : e.envName)  değer=\(v)"
}

func runAsync(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}

guard args.count >= 2 else { usage() }

if args[1] == "--mask" {
    guard args.count >= 3 else { usage() }
    let m = Masker.mask(readFile(args[2]))
    print(m.text)
    print("\n--- \(m.map.count) değer gizlendi:")
    for (tag, v) in m.map.sorted(by: { $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count < $1.key.count }) {
        print("  \(tag) = \(v.count) karakter, sha=\(sha256Hex(v).prefix(12))")
    }
    exit(0)
}

// --contexts [local|ssh]: kubeconfig'teki context'leri listeler (bağlantı testi).
if args[1] == "--contexts" {
    var remote = cfg.remote
    if args.count >= 3, let m = ConnectionMode(rawValue: args[2]) { remote.mode = m }
    do { print(try Remote.listContexts(remote).joined(separator: "\n")) } catch { print("HATA: \(error.localizedDescription)") }
    exit(0)
}

if args[1] == "--read" && args.count < 3 { usage() }
let text = readFile(args[1] == "--read" ? args[2] : args[1])
var outcome: MailReader.Outcome!
runAsync { outcome = await MailReader.read(text, cfg: cfg) }
let r = outcome.result
print("Okuyan: \(outcome.readBy)")
print("Ortam: \(r.context)")
print("Namespace'ler: \(r.namespaces.joined(separator: ", "))")
r.entries.forEach { print(describe($0)) }
r.notes.forEach { print("NOT: \($0)") }
if args[1] == "--read" { exit(0) }

let ctx = args.count >= 3 ? args[2] : (cfg.contexts.contains(r.context) ? r.context : (cfg.contexts.first ?? ""))
let probs = Validate.problems(context: ctx, contexts: cfg.contexts, namespaces: r.namespaces, entries: r.entries)
guard probs.isEmpty else { probs.forEach { print("SORUN: \($0)") }; exit(2) }

do {
    var results = [TargetResult]()
    var names = [String]()
    for e in r.entries where !names.contains(e.secretName) { names.append(e.secretName) }
    for name in names {
        results += try Remote.check(cfg.remote, context: ctx, secretName: name, namespaces: r.namespaces)
    }
    let plan = Planner.plan(results: results, entries: r.entries)
    print("\nPlan (\(ctx), \(cfg.remote.label)):")
    for p in plan {
        let ch = p.changes.map { "\($0.key)=\($0.status)" }.joined(separator: " ")
        print("  \(p.namespace) \(p.secretName): \(p.action)\(p.canUpdate ? " (güncellenebilir)" : "")  [\(ch)]")
    }
    let candidates = Set(plan.filter(\.canUpdate).map(\.id))
    if plan.contains(where: { $0.action == .create }) || !candidates.isEmpty {
        let d = try Remote.apply(cfg.remote, context: ctx, plan: plan, updates: candidates, entries: r.entries, dryRun: true)
        print("\nDry-run (\(d.ok ? "OK" : "HATA")):\n\(d.output)")
    } else {
        print("\nYapılacak işlem yok.")
    }
} catch {
    print("HATA: \(error.localizedDescription)")
    exit(3)
}
