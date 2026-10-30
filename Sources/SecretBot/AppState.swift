import Foundation
import SecretBotCore

@MainActor
final class AppState: ObservableObject {
    @Published var mailText = ""
    @Published var namespacesText = ""
    @Published var entries: [KeyEntry] = []
    @Published var warnings: [String] = []
    @Published var context = ""

    @Published var plan: [PlanItem] = []
    /// Kullanıcının tek tek "güncelle" diye işaretlediği var olan secret'lar (PlanItem.id).
    @Published var selectedUpdates: Set<String> = []
    @Published var checkedFingerprint: String?
    @Published var dryRunOutput = ""
    @Published var dryRunOK = false
    @Published var applyOutput = ""
    @Published var applyOK = false
    @Published var resultMessage = ""
    @Published var busy = false
    @Published var applying = false
    @Published var busyText = ""
    @Published var errorText: String?

    /// Yapay zekâya gönderilen (maskelenmiş) metin.
    @Published var sentToAI = ""
    /// Maili kimin okuduğu.
    @Published var readBy = ""
    @Published private(set) var config = AppConfig.load()
    @Published private(set) var aiStatus = ""
    @Published private(set) var aiAvailable = false

    private var autoTask: Task<Void, Never>?
    private var checkGeneration = 0
    private var readGeneration = 0
    private var lastReadText = ""
    private var defaultsObserver: NSObjectProtocol?

    init() {
        reloadConfig()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadConfig() }
        }
    }

    /// Ayarlar değişince çağrılır.
    func reloadConfig() {
        config = AppConfig.load()
        if !config.contexts.contains(context) { context = config.contexts.first ?? "" }
        aiStatus = MailReader.statusText(config)
        aiAvailable = MailReader.resolve(config) != nil
    }

    var namespaces: [String] {
        var out = [String]()
        for line in namespacesText.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " }) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty && !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// Ekrandaki girdilerin özeti. Kontrolden sonra bir şey değişirse onay kapanır.
    var fingerprint: String {
        let e = entries.map { "\($0.secretName)/\($0.key)=\(sha256Hex($0.value))" }.joined(separator: ";")
        return sha256Hex("\(context)|\(namespaces.joined(separator: ","))|\(e)")
    }

    var isStale: Bool { checkedFingerprint != nil && checkedFingerprint != fingerprint }
    var creates: [PlanItem] { plan.filter { $0.action == .create } }
    var updates: [PlanItem] { plan.filter { $0.canUpdate && selectedUpdates.contains($0.id) } }
    var canApply: Bool {
        !busy && dryRunOK && !isStale && checkedFingerprint != nil && !(creates.isEmpty && updates.isEmpty)
    }

    var confirmTitle: String {
        var parts = [String]()
        if !creates.isEmpty { parts.append("\(creates.count) secret oluşturulacak") }
        if !updates.isEmpty { parts.append("\(updates.count) var olan secret güncellenecek") }
        return "\(context): " + parts.joined(separator: ", ")
    }

    var confirmSummary: String {
        var text = ""
        if !creates.isEmpty {
            text += "OLUŞTURULACAK:\n" + creates.map { "• \($0.namespace) / \($0.secretName)  [\($0.changes.map(\.key).joined(separator: ", "))]" }
                .joined(separator: "\n")
        }
        if !updates.isEmpty {
            if !text.isEmpty { text += "\n\n" }
            text += "⚠️ GÜNCELLENECEK (var olan değerler değişecek):\n" + updates.map { p in
                let keys = p.changes.filter { $0.status != .same }
                    .map { "\($0.key) (\($0.status == .different ? "değer değişir" : "eklenir"))" }.joined(separator: ", ")
                return "• \(p.namespace) / \(p.secretName)  [\(keys)]"
            }.joined(separator: "\n")
        }
        let untouched = plan.filter { $0.action == .exists && !selectedUpdates.contains($0.id) }.count
        if untouched > 0 { text += "\n\nDokunulmayacak: \(untouched) var olan secret." }
        return text
    }

    // Özet sayılar
    var createCount: Int { creates.count }
    var existsSameCount: Int { plan.filter(\.matchesMail).count }
    var existsDiffCount: Int { plan.filter(\.canUpdate).count }
    var skipCount: Int { plan.filter { if case .skip = $0.action { return true }; return false }.count }

    func toggleUpdate(_ id: String, _ on: Bool) {
        if on { selectedUpdates.insert(id) } else { selectedUpdates.remove(id) }
    }

    // MARK: - Mail okuma

    /// Mail metni değişince: kısa bir bekleme sonrası oku ve eksik yoksa otomatik kontrol et.
    func mailChanged() {
        autoTask?.cancel()
        let text = mailText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != lastReadText else { return }
        autoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.readMail()
        }
    }

    func readMail() async {
        guard !applying else { return }
        reloadConfig()
        readGeneration += 1
        let gen = readGeneration
        let text = mailText
        lastReadText = text
        checkGeneration += 1 // devam eden eski kontrolün sonucu gösterilmesin
        resetResults()
        warnings = []
        sentToAI = Masker.mask(text).text

        busy = true
        busyText = aiAvailable ? "Yapay zekâ maili okuyor…" : "Mail okunuyor…"
        let outcome = await MailReader.read(text, cfg: config)
        guard gen == readGeneration else { return }
        busy = false

        let r = outcome.result
        if config.contexts.contains(r.context) { context = r.context }
        namespacesText = r.namespaces.joined(separator: "\n")
        entries = r.entries
        warnings = r.notes
        readBy = outcome.readBy
        autoCheck()
    }

    private func autoCheck() {
        let probs = Validate.problems(context: context, contexts: config.contexts, namespaces: namespaces, entries: entries)
        if probs.isEmpty {
            check()
        } else {
            errorText = "Otomatik kontrol yapılmadı, önce şunları tamamlayın:\n" + probs.joined(separator: "\n")
        }
    }

    /// Ortam değişince elde talep varsa tekrar kontrol et.
    func contextChanged() {
        guard !entries.isEmpty, checkedFingerprint != nil || errorText != nil else { return }
        check()
    }

    func clearAll() {
        guard !applying else { return }
        autoTask?.cancel()
        checkGeneration += 1
        readGeneration += 1
        lastReadText = ""
        busy = false
        mailText = ""; namespacesText = ""; entries = []; warnings = []
        sentToAI = ""; readBy = ""
        resetResults()
    }

    func resetResults() {
        plan = []; selectedUpdates = []; checkedFingerprint = nil
        dryRunOutput = ""; dryRunOK = false
        applyOutput = ""; applyOK = false; resultMessage = ""
        errorText = nil
    }

    func addEntry() {
        entries.append(KeyEntry(secretName: entries.last?.secretName ?? "", key: ""))
    }

    func removeEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    // MARK: - Kontrol ve uygulama

    /// Salt okuma kontrol + dry-run. Sunucuda hiçbir şey değişmez.
    /// Dry-run, oluşturulacakların yanında güncellenebilecek tüm var olan secret'ları da kapsar;
    /// böylece kullanıcı sonradan "güncelle" işaretlerse yeniden kontrol gerekmez.
    func check() {
        guard !applying else { return }
        reloadConfig()
        let ctx = context, nss = namespaces, ents = entries, cfg = config.remote, fp = fingerprint
        let probs = Validate.problems(context: ctx, contexts: config.contexts, namespaces: nss, entries: ents)
        guard probs.isEmpty else { errorText = probs.joined(separator: "\n"); return }
        resetResults()
        checkGeneration += 1
        let gen = checkGeneration
        busy = true; busyText = "\(ctx) ortamında kontrol ediliyor (\(cfg.label))…"
        Task.detached {
            do {
                let plan = try Self.buildPlan(cfg: cfg, ctx: ctx, nss: nss, ents: ents)
                let candidates = Set(plan.filter(\.canUpdate).map(\.id))
                let r: (ok: Bool, output: String) = plan.contains(where: { $0.action == .create }) || !candidates.isEmpty
                    ? try Remote.apply(cfg, context: ctx, plan: plan, updates: candidates, entries: ents, dryRun: true)
                    : (false, "Oluşturulacak veya güncellenebilecek secret yok.")
                await MainActor.run {
                    guard gen == self.checkGeneration else { return }
                    self.plan = plan; self.dryRunOutput = r.output; self.dryRunOK = r.ok
                    self.checkedFingerprint = fp; self.busy = false
                }
            } catch {
                await MainActor.run {
                    guard gen == self.checkGeneration else { return }
                    self.errorText = error.localizedDescription; self.busy = false
                }
            }
        }
    }

    /// Gerçek uygulama. Sadece onay penceresinden sonra çağrılır.
    func apply() {
        guard canApply else { return }
        let ctx = context, nss = namespaces, ents = entries, cfg = config.remote, plan = plan, chosen = selectedUpdates
        let touched = Set(creates.map(\.id) + updates.map(\.id))
        autoTask?.cancel()
        applying = true
        busy = true; busyText = "Uygulanıyor…"
        Task.detached {
            do {
                let r = try Remote.apply(cfg, context: ctx, plan: plan, updates: chosen, entries: ents, dryRun: false)
                OpLog.append(context: ctx, target: cfg.label, plan: plan, updates: chosen, ok: r.ok, output: r.output)
                // Sonucu doğrulamak için tekrar kontrol et.
                let after = try Self.buildPlan(cfg: cfg, ctx: ctx, nss: nss, ents: ents)
                let verified = after.filter { touched.contains($0.id) }.allSatisfy(\.matchesMail)
                await MainActor.run {
                    self.applyOutput = r.output; self.applyOK = r.ok && verified
                    self.resultMessage = verified
                        ? "Tamamlandı ve doğrulandı: işlem yapılan secret'lar sunucuda, değerleri maille aynı."
                        : "Bazı işlemler beklendiği gibi sonuçlanmadı. Durum kartlarına ve teknik ayrıntılara bakın."
                    self.plan = after
                    self.selectedUpdates = []
                    self.dryRunOK = false
                    self.busy = false; self.applying = false
                }
            } catch {
                await MainActor.run { self.errorText = error.localizedDescription; self.busy = false; self.applying = false }
            }
        }
    }

    nonisolated private static func buildPlan(cfg: RemoteConfig, ctx: String, nss: [String], ents: [KeyEntry]) throws -> [PlanItem] {
        var results = [TargetResult]()
        var names = [String]()
        for e in ents where !names.contains(e.secretName) { names.append(e.secretName) }
        for name in names {
            results += try Remote.check(cfg, context: ctx, secretName: name, namespaces: nss)
        }
        return Planner.plan(results: results, entries: ents)
    }
}
