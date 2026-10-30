import Foundation

public enum ConnectionMode: String, CaseIterable, Identifiable {
    case local, ssh
    public var id: String { rawValue }
}

public struct RemoteConfig {
    public var mode: ConnectionMode
    public var user: String
    public var host: String
    public init(mode: ConnectionMode, user: String = "", host: String = "") {
        self.mode = mode; self.user = user; self.host = host
    }
    public var label: String { mode == .local ? "bu bilgisayardaki kubectl" : "\(user)@\(host)" }
}

public struct RemoteError: LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// kubectl komutlarını ya bu bilgisayarda ya da SSH ile bir sunucuda çalıştırır.
/// Script her zaman stdin'den gider; secret değerleri hiçbir komut satırında (ps çıktısında) görünmez.
public enum Remote {
    static func run(_ cfg: RemoteConfig, script: String, args: [String]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        switch cfg.mode {
        case .ssh:
            guard Validate.isSSHUser(cfg.user), Validate.isSSHHost(cfg.host) else {
                throw RemoteError("SSH kullanıcı/sunucu ayarı eksik veya geçersiz. Ayarlar'ı (⌘,) kontrol edin.")
            }
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                           "\(cfg.user)@\(cfg.host)", "bash", "-s", "--"] + args
        case .local:
            // Kullanıcının login kabuğu: kubectl'in PATH'i ve KUBECONFIG ayarları gelsin.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-l", "-c",
                           #"export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"; exec /bin/bash -s -- "$@""#,
                           "secretbot"] + args
        }
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP
        p.standardOutput = outP
        p.standardError = errP
        try p.run()

        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = outP.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = errP.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        inP.fileHandleForWriting.write(Data(script.utf8))
        try? inP.fileHandleForWriting.close()
        g.wait()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }

    // MARK: - Kurulum yardımcıları

    /// kubeconfig'teki context adlarını listeler.
    public static func listContexts(_ cfg: RemoteConfig) throws -> [String] {
        let r = try run(cfg, script: "kubectl config get-contexts -o name\n", args: [])
        guard r.code == 0 else { throw RemoteError("Context'ler alınamadı: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return r.out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Her context için cluster'a erişilebiliyor mu bakar.
    public static func testContexts(_ cfg: RemoteConfig, contexts: [String]) throws -> [(String, Bool, String)] {
        let valid = contexts.filter(Validate.isContextName)
        let script = #"""
        for c in "$@"; do
          if out=$(kubectl --context "$c" get ns default -o name --request-timeout=10s 2>&1); then echo "OK $c"
          else echo "FAIL $c $(echo "$out" | head -1 | cut -c1-160)"; fi
        done
        """#
        let r = try run(cfg, script: script, args: valid)
        return r.out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }
            return (parts[1], parts[0] == "OK", parts.count > 2 ? parts[2] : "")
        }
    }

    // MARK: - Kontrol (salt okuma)

    private static let checkScript = #"""
    ctx="$1"; name="$2"; shift 2
    errf=$(mktemp); trap 'rm -f "$errf"' EXIT
    if ! kubectl --context "$ctx" get ns default -o name >/dev/null 2>"$errf"; then
      echo "ERR cluster'a ulaşılamadı: $(head -c 300 "$errf" | tr '\n' ' ')"; exit 3
    fi
    for ns in "$@"; do
      if ! kubectl --context "$ctx" get ns "$ns" -o name >/dev/null 2>"$errf"; then
        if grep -q NotFound "$errf"; then echo "NS $ns NSMISSING"; else echo "NS $ns ERROR $(head -c 200 "$errf" | tr '\n' ' ')"; fi
        continue
      fi
      if json=$(kubectl --context "$ctx" -n "$ns" get secret "$name" -o json 2>"$errf"); then
        echo "NS $ns SECRET"
        printf '%s' "$json" | python3 -c '
    import sys, json, base64, hashlib
    o = json.load(sys.stdin)
    print("RV", o.get("metadata", {}).get("resourceVersion", ""))
    for k, v in sorted((o.get("data") or {}).items()):
        print("KEY", k, hashlib.sha256(base64.b64decode(v)).hexdigest())
    '
      elif grep -q NotFound "$errf"; then echo "NS $ns NOSECRET"
      else echo "NS $ns ERROR $(head -c 200 "$errf" | tr '\n' ' ')"; fi
    done
    """#

    public static func check(_ cfg: RemoteConfig, context: String, secretName: String, namespaces: [String]) throws -> [TargetResult] {
        guard Validate.isContextName(context), Validate.isName(secretName), namespaces.allSatisfy(Validate.isName) else {
            throw RemoteError("Geçersiz ortam, secret veya namespace adı.")
        }
        let r = try run(cfg, script: checkScript, args: [context, secretName] + namespaces)

        var results = [TargetResult]()
        var curNS: String?
        var curKind = ""
        var curMsg = ""
        var keys = [String: String]()
        var rv = ""
        func flush() {
            guard let ns = curNS else { return }
            let state: TargetState
            switch curKind {
            case "SECRET": state = .exists(keys, resourceVersion: rv)
            case "NSMISSING": state = .nsMissing
            case "NOSECRET": state = .secretMissing
            default: state = .error(curMsg)
            }
            results.append(TargetResult(secretName: secretName, namespace: ns, state: state))
            curNS = nil; keys = [:]; rv = ""
        }
        for line in r.out.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            if parts.first == "ERR" { throw RemoteError(line.dropFirst(4).description) }
            if parts.first == "NS", parts.count >= 3 {
                flush()
                curNS = parts[1]; curKind = parts[2]; curMsg = parts.count > 3 ? parts[3] : ""
            } else if parts.first == "KEY", parts.count >= 3 {
                keys[parts[1]] = parts[2]
            } else if parts.first == "RV", parts.count >= 2 {
                rv = parts[1]
            }
        }
        flush()
        if results.isEmpty {
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError("Sonuç alınamadı (kod \(r.code)) [\(cfg.label)]: \(err.isEmpty ? "kubectl çıktısı boş" : err)")
        }
        return results
    }

    // MARK: - Uygulama (dry-run veya gerçek)

    /// Plan'daki `.create` öğelerini oluşturur. `updates` içindeki (kullanıcının tek tek onayladığı) var olan
    /// secret'larda sadece farklı/eksik key'leri yazar; diğer key'lere dokunmaz.
    public static func apply(_ cfg: RemoteConfig, context: String, plan: [PlanItem], updates: Set<String>,
                             entries: [KeyEntry], dryRun: Bool) throws -> (ok: Bool, output: String) {
        guard Validate.isContextName(context) else { throw RemoteError("Geçersiz ortam.") }
        let dry = dryRun ? " --dry-run=server" : ""
        var s = """
        umask 077
        ctx="$1"
        tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
        rc=0

        """
        func add(_ item: PlanItem, obj: [String: Any], cmd: String, verb: String) throws {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
            s += """
            cat > "$tmp" <<'__SB_JSON__'
            \(json)
            __SB_JSON__
            if out=$(\(cmd) 2>&1); then echo "OK   \(verb) \(item.namespace)/\(item.secretName): $out"; else echo "HATA \(verb) \(item.namespace)/\(item.secretName): $out"; rc=1; fi

            """
        }
        func data(for item: PlanItem, onlyKeys: Set<String>?) throws -> [String: String] {
            var d = [String: String]()
            for e in entries where e.secretName == item.secretName && (onlyKeys?.contains(e.key) ?? true) {
                guard Validate.isKey(e.key) else { throw RemoteError("Geçersiz key: \(e.key)") }
                d[e.key] = Data(e.value.utf8).base64EncodedString()
            }
            return d
        }

        for item in plan {
            guard Validate.isName(item.secretName), Validate.isName(item.namespace) else { throw RemoteError("Geçersiz ad: \(item.id)") }
            if item.action == .create {
                let obj: [String: Any] = ["apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                                          "metadata": ["name": item.secretName, "namespace": item.namespace],
                                          "data": try data(for: item, onlyKeys: nil)]
                // `create` (apply değil): secret bu arada oluşmuşsa "AlreadyExists" ile durur, üzerine yazmaz.
                try add(item, obj: obj, cmd: #"kubectl --context "$ctx" create -f "$tmp""# + dry, verb: "oluştur")
            } else if item.canUpdate && updates.contains(item.id) {
                guard !item.resourceVersion.isEmpty, item.resourceVersion.allSatisfy(\.isNumber) else {
                    throw RemoteError("\(item.id) için sürüm bilgisi yok; tekrar kontrol edin.")
                }
                let changed = Set(item.changes.filter { $0.status != .same }.map(\.key))
                // resourceVersion: kontrolden sonra secret değiştiyse sunucu "Conflict" ile reddeder.
                let obj: [String: Any] = ["metadata": ["resourceVersion": item.resourceVersion],
                                          "data": try data(for: item, onlyKeys: changed)]
                let cmd = #"kubectl --context "$ctx" -n \#(item.namespace) patch secret \#(item.secretName) --type merge --patch-file "$tmp""# + dry
                try add(item, obj: obj, cmd: cmd, verb: "güncelle")
            }
        }
        s += "exit $rc\n"
        let r = try run(cfg, script: s, args: [context])
        var output = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        // kubectl patch dry-run'da "(server dry run)" yazmıyor; karışmasın diye her satırı etiketle.
        if dryRun { output = output.split(separator: "\n").map { "[DRY-RUN] \($0)" }.joined(separator: "\n") }
        return (r.code == 0, output)
    }
}

public enum Planner {
    public static func plan(results: [TargetResult], entries: [KeyEntry]) -> [PlanItem] {
        results.map { r in
            let es = entries.filter { $0.secretName == r.secretName }
            let allMissing = es.map { KeyChange(key: $0.key, status: .missing) }
            switch r.state {
            case .nsMissing:
                return PlanItem(secretName: r.secretName, namespace: r.namespace, action: .skip("namespace yok"), changes: allMissing)
            case .error(let m):
                return PlanItem(secretName: r.secretName, namespace: r.namespace, action: .skip("hata: \(m)"), changes: allMissing)
            case .secretMissing:
                return PlanItem(secretName: r.secretName, namespace: r.namespace, action: .create, changes: allMissing)
            case .exists(let hashes, let rv):
                // Varsayılan: dokunulmaz. Karşılaştırma, kullanıcının güncelleme kararı için.
                let changes = es.map { e -> KeyChange in
                    guard let h = hashes[e.key] else { return KeyChange(key: e.key, status: .missing) }
                    return KeyChange(key: e.key, status: h == sha256Hex(e.value) ? .same : .different)
                }
                return PlanItem(secretName: r.secretName, namespace: r.namespace, action: .exists,
                                changes: changes, resourceVersion: rv)
            }
        }
    }
}

/// Yapılan işlemlerin kaydı. Değer yazılmaz, sadece ad/key/sonuç.
public enum OpLog {
    public static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("islem.log")
    }

    public static func append(context: String, target: String, plan: [PlanItem], updates: Set<String>, ok: Bool, output: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        var text = "=== \(ts) ortam=\(context) hedef=\(target) sonuç=\(ok ? "BAŞARILI" : "HATALI")\n"
        for p in plan {
            if p.action == .create {
                text += "  oluştur  \(p.namespace)/\(p.secretName) keys=[\(p.changes.map(\.key).joined(separator: ","))]\n"
            } else if p.canUpdate && updates.contains(p.id) {
                let keys = p.changes.filter { $0.status != .same }.map(\.key).joined(separator: ",")
                text += "  güncelle \(p.namespace)/\(p.secretName) keys=[\(keys)]\n"
            }
        }
        text += output.split(separator: "\n").map { "  > \($0)" }.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
