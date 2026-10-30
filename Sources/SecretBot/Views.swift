import SwiftUI
import AppKit
import SecretBotCore

private let mono = Font.system(.body, design: .monospaced)
private let monoSmall = Font.system(.callout, design: .monospaced)

// MARK: - Ana pencere

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var confirming = false
    @State private var editing = false

    private var isEmpty: Bool {
        state.mailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.entries.isEmpty && !state.busy
    }

    var body: some View {
        HSplitView {
            MailPane()
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
            rightPane
                .frame(minWidth: 640)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .toolbar { toolbarContent }
        .onChange(of: state.mailText) { state.mailChanged() }
        .onChange(of: state.context) { state.contextChanged() }
        .confirmationDialog(state.confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(state.updates.isEmpty ? "Onay, oluştur" : "Onay, uygula", role: state.updates.isEmpty ? nil : .destructive) { state.apply() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(state.confirmSummary)
        }
    }

    // MARK: Araç çubuğu

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Ortam", selection: $state.context) {
                ForEach(state.config.contexts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.applying || state.config.contexts.isEmpty)
            .help("Kontrolün ve işlemin yapılacağı cluster context'i (\(state.config.remote.label))")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await state.readMail() } } label: { Label("Yeniden oku", systemImage: "sparkles") }
                .help("Maili yapay zekâ ile yeniden oku")
                .disabled(state.busy || state.mailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button { state.check() } label: { Label("Tekrar kontrol et", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Sunucuda tekrar kontrol et (salt okuma) — ⌘R")
                .disabled(state.busy || state.entries.isEmpty)
            Button { state.clearAll(); editing = false } label: { Label("Temizle", systemImage: "xmark.circle") }
                .keyboardShortcut("k", modifiers: .command)
                .help("Her şeyi temizle — ⌘K")
                .disabled(state.applying)
            Button { NSWorkspace.shared.open(OpLog.url) } label: { Label("İşlem kaydı", systemImage: "list.bullet.rectangle") }
                .help("Yapılan işlemlerin kaydını aç")
        }
    }

    // MARK: Sağ panel

    private var rightPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !state.config.isConfigured {
                        SetupBanner()
                    }
                    if isEmpty {
                        EmptyStateView()
                    } else {
                        if state.busy {
                            Banner(kind: .info, text: state.busyText, showsProgress: true)
                        }
                        if let err = state.errorText {
                            Banner(kind: .error, text: err)
                        }
                        if !state.applyOutput.isEmpty {
                            Banner(kind: state.applyOK ? .success : .error, text: state.resultMessage)
                        }
                        if !state.plan.isEmpty { summaryTiles }
                        requestCard
                        if !state.plan.isEmpty { statusCard }
                        detailsSection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionBar
        }
    }

    // MARK: Özet

    private var summaryTiles: some View {
        HStack(spacing: 12) {
            StatTile(count: state.createCount, title: "oluşturulacak", icon: "plus.circle.fill", color: .green)
            StatTile(count: state.existsSameCount, title: "zaten var, aynı", icon: "checkmark.seal.fill", color: .teal)
            if state.existsDiffCount > 0 {
                StatTile(count: state.existsDiffCount, title: "zaten var, farklı (\(state.updates.count) güncellenecek)", icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if state.skipCount > 0 {
                StatTile(count: state.skipCount, title: "atlanacak", icon: "xmark.octagon.fill", color: .red)
            }
        }
    }

    // MARK: Talep kartı

    private var requestCard: some View {
        Card(title: "Talep", icon: "doc.text.magnifyingglass") {
            HStack(spacing: 8) {
                if !state.readBy.isEmpty {
                    Chip(text: state.readBy, color: .purple, icon: "sparkles")
                }
                Button(editing ? "Bitti" : "Düzenle") { editing.toggle() }
                    .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !state.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.warnings, id: \.self) { w in
                            Label(w, systemImage: "lightbulb")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
                }
                if editing || state.entries.isEmpty {
                    RequestEditor()
                } else {
                    requestSummary
                }
            }
        }
    }

    private var requestSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow(title: "Secret") {
                FlowLayout {
                    ForEach(Array(Set(state.entries.map(\.secretName))).sorted(), id: \.self) {
                        Chip(text: $0, color: .blue, icon: "key.fill", monospaced: true)
                    }
                }
            }
            LabeledRow(title: "Namespace (\(state.namespaces.count))") {
                FlowLayout {
                    ForEach(state.namespaces, id: \.self) { Chip(text: $0, color: .gray, monospaced: true) }
                }
            }
            LabeledRow(title: "Key'ler") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(state.entries) { e in
                        GridRow {
                            Text(e.key).font(monoSmall).bold()
                            Text(e.envName.isEmpty ? "—" : e.envName).font(monoSmall).foregroundStyle(.secondary)
                            MaskedValue(value: e.value)
                        }
                    }
                }
            }
        }
    }

    // MARK: Durum kartı

    private var statusCard: some View {
        Card(title: "Sunucudaki durum", icon: "server.rack") {
            Text(state.context + " cluster").font(.caption).foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if state.isStale {
                    Banner(kind: .warning, text: "Kontrolden sonra alanlar değişti. Tekrar kontrol edin (⌘R).")
                        .padding(.bottom, 10)
                }
                ForEach(Array(state.plan.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().padding(.vertical, 8) }
                    StatusRow(item: item, selected: item.canUpdate ? Binding(
                        get: { state.selectedUpdates.contains(item.id) },
                        set: { state.toggleUpdate(item.id, $0) }) : nil)
                    .disabled(state.busy)
                }
            }
        }
    }

    // MARK: Teknik ayrıntılar

    @ViewBuilder
    private var detailsSection: some View {
        if !state.dryRunOutput.isEmpty || !state.applyOutput.isEmpty {
            DisclosureGroup("Teknik ayrıntılar") {
                VStack(alignment: .leading, spacing: 10) {
                    if !state.applyOutput.isEmpty {
                        OutputBlock(title: "İşlem çıktısı", text: state.applyOutput)
                    }
                    if !state.dryRunOutput.isEmpty && state.applyOutput.isEmpty {
                        OutputBlock(title: "Dry-run çıktısı (sunucuda hiçbir şey değişmedi)", text: state.dryRunOutput)
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    // MARK: Onay çubuğu

    private var actionMessage: (String, String, Color) {
        if state.busy { return (state.busyText, "hourglass", .secondary) }
        if state.isStale { return ("Alanlar değişti, tekrar kontrol edin.", "arrow.clockwise", .orange) }
        if state.plan.isEmpty { return ("Mail okununca sunucu kontrolü otomatik yapılır.", "info.circle", .secondary) }
        if state.creates.isEmpty && state.updates.isEmpty {
            return state.existsDiffCount > 0
                ? ("Oluşturulacak secret yok. Farklı olanları güncellemek isterseniz kartlardan seçin.", "hand.point.up.left", .secondary)
                : ("Oluşturulacak secret yok. Var olan secret'lara dokunulmaz.", "checkmark.circle", .secondary)
        }
        if !state.dryRunOK { return ("Dry-run hata verdi, teknik ayrıntılara bakın.", "xmark.octagon", .red) }
        var parts = [String]()
        if !state.creates.isEmpty { parts.append("\(state.creates.count) oluşturma") }
        if !state.updates.isEmpty { parts.append("\(state.updates.count) güncelleme") }
        return ("Dry-run başarılı. \(parts.joined(separator: " ve ")) onayınızı bekliyor.", "hand.raised", state.updates.isEmpty ? .primary : .orange)
    }

    private var applyButtonTitle: String {
        switch (state.creates.count, state.updates.count) {
        case (0, 0): return "Onayla ve uygula"
        case (let c, 0): return "Onayla ve \(c) secret oluştur"
        case (0, let u): return "Onayla ve \(u) secret güncelle"
        case (let c, let u): return "Onayla: \(c) oluştur, \(u) güncelle"
        }
    }

    private var actionBar: some View {
        let (msg, icon, color) = actionMessage
        return HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color)
            Text(msg).foregroundStyle(color).lineLimit(2)
            Spacer()
            Button { confirming = true } label: {
                Label(applyButtonTitle, systemImage: "checkmark.shield.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.updates.isEmpty ? .accentColor : .orange)
            .controlSize(.large)
            .disabled(!state.canApply)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Mail paneli

struct MailPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mail", systemImage: "envelope.open").font(.headline)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { state.mailText = s }
                } label: { Label("Panodan yapıştır", systemImage: "doc.on.clipboard") }
                    .controlSize(.small)
                    .disabled(state.applying)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.mailText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if state.mailText.isEmpty {
                    Text("Secret talep mailini buraya yapıştırın.\n\nMail otomatik okunur ve sunucuda kontrol edilir. Onayınız olmadan hiçbir şey değişmez.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))

            aiStatus

            if !state.sentToAI.isEmpty && state.aiAvailable {
                DisclosureGroup("Yapay zekâya giden metin") {
                    ScrollView {
                        Text(state.sentToAI)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .font(.caption)
            }
        }
        .padding(16)
    }

    private var aiStatus: some View {
        let (text, color): (String, Color) = (state.aiStatus, state.aiAvailable ? .green : .orange)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
            if state.aiAvailable {
                Text("· değerler gizlenerek gönderilir").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

// MARK: - Talep düzenleyici

struct RequestEditor: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Namespace'ler (her satıra bir tane)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $state.namespacesText)
                    .font(monoSmall)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Key'ler").font(.caption).foregroundStyle(.secondary)
                ForEach($state.entries) { $e in
                    HStack(spacing: 8) {
                        TextField("secret adı", text: $e.secretName).frame(width: 170)
                        TextField("key", text: $e.key).frame(width: 140)
                        TextField("ENV_ADI (bilgi)", text: $e.envName).frame(width: 150)
                        SecretValueField(value: $e.value)
                        Button { state.removeEntry(e.id) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("Bu key'i çıkar")
                    }
                    .font(monoSmall)
                    .textFieldStyle(.roundedBorder)
                }
                Button { state.addEntry() } label: { Label("Key ekle", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Durum satırı

struct StatusRow: View {
    let item: PlanItem
    /// Sadece var olan ama farklı secret'larda: kullanıcı güncellemeyi seçebilir.
    var selected: Binding<Bool>? = nil

    private var look: (icon: String, color: Color, text: String) {
        switch item.action {
        case .create:
            return ("plus.circle.fill", .green, "Secret yok, oluşturulacak.")
        case .exists where item.matchesMail:
            return ("checkmark.seal.fill", .teal, "Zaten var, değerler maille aynı. Dokunulmayacak.")
        case .exists:
            return ("exclamationmark.triangle.fill", .orange, "Zaten var ama maildekinden farklı. Varsayılan olarak dokunulmaz.")
        case .skip(let m):
            return ("xmark.octagon.fill", .red, "Atlanacak: \(m)")
        }
    }

    var body: some View {
        let l = look
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: l.icon).font(.title2).foregroundStyle(l.color).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.namespace).font(mono).bold().textSelection(.enabled)
                    Text(item.secretName).font(monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(l.text).font(.callout).foregroundStyle(l.color == .teal ? .secondary : l.color)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout {
                    ForEach(item.changes, id: \.self) { KeyChip(change: $0, creating: item.action == .create) }
                }
                if let selected {
                    Toggle(isOn: selected) {
                        Text("Maildeki değerlerle güncelle (onaya tabi)").font(.callout)
                    }
                    .toggleStyle(.checkbox)
                    .help("Sadece farklı/eksik key'ler yazılır, diğer key'ler korunur. Kontrolden sonra secret başka biri tarafından değiştirildiyse güncelleme reddedilir.")
                    if selected.wrappedValue {
                        Text("Sadece farklı/eksik key'ler yazılacak; diğer key'ler korunur. Onay penceresinde ayrıca gösterilir.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

struct KeyChip: View {
    let change: KeyChange
    let creating: Bool

    var body: some View {
        let (suffix, color, icon): (String, Color, String) = {
            if creating { return ("", .green, "plus") }
            switch change.status {
            case .same: return ("aynı", .teal, "checkmark")
            case .different: return ("farklı", .orange, "exclamationmark")
            case .missing: return ("secret'ta yok", .gray, "minus")
            }
        }()
        Chip(text: suffix.isEmpty ? change.key : "\(change.key) · \(suffix)", color: color, icon: icon, monospaced: true)
    }
}

// MARK: - Boş durum

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.linearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.top, 40)
            Text("Başlamak için maili sol tarafa yapıştırın").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                StepRow(n: 1, title: "Yapıştır", text: "Mail yapay zekâ ile okunur; secret değerleri gönderilmeden önce gizlenir.")
                StepRow(n: 2, title: "Kontrol", text: "Her namespace sunucuda otomatik kontrol edilir. Bu adım sadece okur.")
                StepRow(n: 3, title: "Onayla", text: "Olmayan secret'lar oluşturulur. Var olanlara dokunulmaz; farklı olanları ancak siz seçip onaylarsanız güncellenir.")
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StepRow: View {
    let n: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Ortak bileşenler

struct Card<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    let trailing: Trailing
    let content: Content

    init(title: String, icon: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon).font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatTile: View {
    let count: Int
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)").font(.title.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(count > 0 ? 0.12 : 0.05)))
        .opacity(count > 0 ? 1 : 0.6)
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var icon: String? = nil
    var monospaced = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(text).font(monospaced ? .system(.caption, design: .monospaced) : .caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color == .gray ? Color.primary : color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

enum BannerKind { case info, success, warning, error }

struct Banner: View {
    let kind: BannerKind
    let text: String
    var showsProgress = false

    var body: some View {
        let (icon, color): (String, Color) = {
            switch kind {
            case .info: return ("info.circle.fill", .blue)
            case .success: return ("checkmark.circle.fill", .green)
            case .warning: return ("exclamationmark.triangle.fill", .orange)
            case .error: return ("xmark.octagon.fill", .red)
            }
        }()
        HStack(alignment: .top, spacing: 10) {
            if showsProgress { ProgressView().controlSize(.small) } else { Image(systemName: icon).foregroundStyle(color) }
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }
}

struct OutputBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}

/// Değeri varsayılan olarak gizli gösterir (uzunluğuyla); göz ikonuyla açılır.
struct MaskedValue: View {
    let value: String
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 6) {
            if value.isEmpty {
                Text("değer yok").font(.caption).foregroundStyle(.red)
            } else if reveal {
                Text(value).font(monoSmall).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            } else {
                Text("••••••  \(value.count) karakter").font(.caption).foregroundStyle(.secondary)
            }
            if !value.isEmpty {
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(reveal ? "Gizle" : "Göster")
            }
        }
    }
}

struct SecretValueField: View {
    @Binding var value: String
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 4) {
            if reveal {
                TextField("değer", text: $value)
            } else {
                SecureField("değer", text: $value)
            }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(reveal ? "Gizle" : "Göster")
        }
    }
}

/// Satıra sığmayan öğeleri alt satıra geçiren basit akış düzeni.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Kurulum uyarısı

struct SetupBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gearshape.2.fill").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("İlk kurulum").font(.headline)
                Text("Ayarlar'dan kubectl'e nasıl erişileceğini (bu bilgisayar veya SSH ile bir sunucu) ve kullanılacak cluster context'lerini seçin. İsterseniz yapay zekâ sağlayıcınızı da bağlayın.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Ayarları aç") }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.10)))
    }
}

// MARK: - Ayarlar

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettings().tabItem { Label("Bağlantı", systemImage: "network") }
            AISettings().tabItem { Label("Yapay zekâ", systemImage: "sparkles") }
            EnvironmentSettings().tabItem { Label("Ortam", systemImage: "text.book.closed") }
        }
        .frame(width: 560, height: 520)
    }
}

struct ConnectionSettings: View {
    @AppStorage(AppConfig.Key.connMode) private var mode = ConnectionMode.local.rawValue
    @AppStorage(AppConfig.Key.sshUser) private var user = ""
    @AppStorage(AppConfig.Key.sshHost) private var host = ""
    @AppStorage(AppConfig.Key.contexts) private var contexts = ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        Form {
            Section("kubectl nerede çalışsın?") {
                Picker("Bağlantı", selection: $mode) {
                    Text("Bu bilgisayarda").tag(ConnectionMode.local.rawValue)
                    Text("SSH ile bir sunucuda").tag(ConnectionMode.ssh.rawValue)
                }
                .pickerStyle(.radioGroup)
                if mode == ConnectionMode.ssh.rawValue {
                    TextField("SSH kullanıcı", text: $user, prompt: Text("ör. ali"))
                    TextField("Sunucu", text: $host, prompt: Text("ör. 10.0.0.5 veya jump.sirket.local"))
                    Text("Bağlantı ~/.ssh altındaki anahtarla yapılır; şifre saklanmaz. Sunucuda kubectl ve python3 kurulu olmalı.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Bu bilgisayardaki kubectl ve kubeconfig (~/.kube/config veya KUBECONFIG) kullanılır. python3 gerekir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Cluster context'leri") {
                TextField("Context'ler (virgülle)", text: $contexts, prompt: Text("ör. dev, prod-eu"))
                HStack {
                    Button("kubeconfig'ten getir") { run { cfg in
                        let list = try Remote.listContexts(cfg)
                        await MainActor.run { contexts = list.joined(separator: ", ") }
                        return "\(list.count) context bulundu. Kullanmayacaklarınızı silebilirsiniz."
                    } }
                    Button("Bağlantıyı test et") { run { cfg in
                        let ctxs = AppConfig.load().contexts
                        guard !ctxs.isEmpty else { return "Önce en az bir context girin." }
                        return try Remote.testContexts(cfg, contexts: ctxs)
                            .map { "\($0.1 ? "✅" : "❌") \($0.0)\($0.1 ? "" : ": " + $0.2)" }.joined(separator: "\n")
                    } }
                    if testing { ProgressView().controlSize(.small) }
                }
                if !testResult.isEmpty {
                    Text(testResult).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ job: @escaping (RemoteConfig) async throws -> String) {
        testing = true; testResult = ""
        let cfg = AppConfig.load().remote
        Task.detached {
            let text: String
            do { text = try await job(cfg) } catch { text = "Hata: \(error.localizedDescription)" }
            await MainActor.run { testResult = text; testing = false }
        }
    }
}

struct AISettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(AppConfig.Key.aiProvider) private var provider = AIProvider.auto.rawValue
    @AppStorage(AppConfig.Key.claudeCodeModel) private var claudeCodeModel = AppConfig.defaultModel
    @AppStorage(AppConfig.Key.anthropicModel) private var anthropicModel = AppConfig.defaultModel
    @AppStorage(AppConfig.Key.openaiBaseURL) private var openaiBaseURL = ""
    @AppStorage(AppConfig.Key.openaiModel) private var openaiModel = ""
    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                Picker("Sağlayıcı", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Şu an kullanılan") {
                    Text(state.aiStatus).foregroundStyle(state.aiAvailable ? .green : .orange)
                }
                Text("Otomatik: sırayla Claude Code → Anthropic API → OpenAI uyumlu uç nokta. Hiçbiri yoksa basit okuyucu kullanılır. Her durumda maildeki değerler gönderilmeden önce <<S1>> gibi etiketlerle gizlenir.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Claude Code (Claude Pro/Max aboneliği)") {
                LabeledContent("Durum") {
                    Text(ClaudeCodeExtractor.findCLI() != nil ? "Kurulu" : "Bulunamadı")
                        .foregroundStyle(ClaudeCodeExtractor.findCLI() != nil ? .green : .secondary)
                }
                TextField("Model", text: $claudeCodeModel)
                Text("API anahtarı gerekmez. Oturum kapalıysa terminalde `claude` yazıp /login ile giriş yapın.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anthropic API") {
                LabeledContent("Anahtar") {
                    Text(APIKeyStore.read(APIKeyStore.anthropic) != nil ? "Kayıtlı" : "Yok").foregroundStyle(.secondary)
                }
                SecureField("Yeni anahtar (sk-ant-…)", text: $anthropicKey)
                TextField("Model", text: $anthropicModel)
                keyButtons(account: APIKeyStore.anthropic, value: $anthropicKey)
            }
            Section("OpenAI uyumlu uç nokta (OpenAI, Ollama, LM Studio, şirket gateway'i…)") {
                TextField("Adres", text: $openaiBaseURL, prompt: Text("ör. https://api.openai.com/v1 veya http://localhost:11434/v1"))
                TextField("Model", text: $openaiModel, prompt: Text("ör. gpt-4.1 veya llama3.1"))
                LabeledContent("Anahtar") {
                    Text(APIKeyStore.read(APIKeyStore.openai) != nil ? "Kayıtlı" : "Yok (yerel modeller için gerekmez)").foregroundStyle(.secondary)
                }
                SecureField("Yeni anahtar (isteğe bağlı)", text: $openaiKey)
                keyButtons(account: APIKeyStore.openai, value: $openaiKey)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func keyButtons(account: String, value: Binding<String>) -> some View {
        HStack {
            Button("Anahtarı kaydet") {
                message = APIKeyStore.save(value.wrappedValue, account: account) ? "Anahtar Keychain'e kaydedildi." : "Kaydedilemedi."
                value.wrappedValue = ""
                state.reloadConfig()
            }
            .disabled(value.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Anahtarı sil", role: .destructive) {
                APIKeyStore.delete(account); message = "Anahtar silindi."; state.reloadConfig()
            }
            .disabled(APIKeyStore.read(account) == nil)
        }
    }
}

struct EnvironmentSettings: View {
    @AppStorage(AppConfig.Key.envDescription) private var envDescription = ""
    @AppStorage(AppConfig.Key.namespacePrefixes) private var prefixes = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $envDescription)
                    .font(.callout)
                    .frame(minHeight: 200)
                Button("Örnek metni yükle") { envDescription = AppConfig.defaultEnvDescription }
                    .disabled(!envDescription.isEmpty)
            } header: {
                Text("Ortam açıklaması (yapay zekâya)")
            } footer: {
                Text("Cluster'larınızı, namespace isimlendirmenizi ve hangi namespace'in hangi context'te olduğunu kısaca anlatın. Ör: \"team-<env>-<uygulama> namespace'leri dev context'indedir; altyapı servisleri shared'dadır.\" Boş bırakılırsa genel bir açıklama kullanılır. Buraya secret değeri yazmayın.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Önekler (virgülle)", text: $prefixes, prompt: Text("ör. team-, app-"))
            } header: {
                Text("Namespace önekleri (basit okuyucu için)")
            } footer: {
                Text("Yapay zekâ yokken mailde bu öneklerle başlayan adlar namespace kabul edilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
