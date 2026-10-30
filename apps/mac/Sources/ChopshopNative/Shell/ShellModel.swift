import Foundation
import CoreGraphics

public enum ShellTarget: Hashable, Sendable {
    case city
    case project(String)
    case thread(id: String, project: String)

    public var project: String? {
        switch self {
        case .city: return nil
        case .project(let p), .thread(_, let p): return p
        }
    }
    public var threadID: String? {
        if case .thread(let id, _) = self { return id }
        return nil
    }
}

public struct ShellFocus: Equatable, Sendable {
    public var target: ShellTarget
    public var token: Int
    public init(target: ShellTarget, token: Int) { self.target = target; self.token = token }
}

public struct ShellWorldContext {
    public var focus: ShellFocus?
    public var ownsEscape: Bool
    public var select: (ShellTarget) -> Void
    public init(focus: ShellFocus?, ownsEscape: Bool, select: @escaping (ShellTarget) -> Void) {
        self.focus = focus; self.ownsEscape = ownsEscape; self.select = select
    }
}

public enum ShellPanel: String, CaseIterable, Identifiable, Sendable {
    case attention, activity, batches, reactions, machineRoom, machines
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .attention: return "Atención"
        case .activity: return "Actividad"
        case .batches: return "Lotes"
        case .reactions: return "Reacciones"
        case .machineRoom: return "Sala de máquinas"
        case .machines: return "Máquinas"
        }
    }
    public var symbol: String {
        switch self {
        case .attention: return "exclamationmark.bubble"
        case .activity: return "waveform.path.ecg"
        case .batches: return "square.stack.3d.up"
        case .reactions: return "bolt.horizontal"
        case .machineRoom: return "server.rack"
        case .machines: return "gauge.with.dots.needle.50percent"
        }
    }
}

public enum ShellInspector: Hashable, Sendable {
    case panel(ShellPanel)
    case target(ShellTarget)
}

public struct ShellState: Equatable, Sendable {
    public var inspector: ShellInspector?
    public var lastInspector: ShellInspector = .panel(.attention)
    public var paletteOpen = false
    public var query = ""
    public var minimap = true
    public var focus: ShellFocus?
    public var selectedThread: String?
    public var attentionCursor = -1

    public init() {}

    public mutating func select(_ target: ShellTarget) {
        if target == .city { selectedThread = nil; return }
        selectedThread = target.threadID
        show(.target(target))
    }

    public mutating func go(_ target: ShellTarget) {
        focus = ShellFocus(target: target, token: (focus?.token ?? 0) + 1)
        if target == .city { selectedThread = nil; return }
        select(target)
    }

    public mutating func toggle(_ panel: ShellPanel) {
        if inspector == .panel(panel) { inspector = nil } else { show(.panel(panel)) }
    }

    public mutating func toggleInspector() {
        if inspector == nil { inspector = lastInspector } else { inspector = nil }
    }

    public mutating func openPalette() { paletteOpen = true; query = "" }
    public mutating func closePalette() { paletteOpen = false; query = "" }

    @discardableResult
    public mutating func escape() -> Bool {
        if paletteOpen { closePalette(); return true }
        if inspector != nil { inspector = nil; return true }
        return false
    }

    @discardableResult
    public mutating func cycleAttention(_ items: [ShellAttentionItem], forward: Bool = true) -> ShellAttentionItem? {
        guard !items.isEmpty else { attentionCursor = -1; return nil }
        if let sel = selectedThread, let i = items.firstIndex(where: { $0.threadID == sel }) { attentionCursor = i }
        let n = items.count
        if attentionCursor < 0 || attentionCursor >= n {
            attentionCursor = forward ? 0 : n - 1
        } else {
            attentionCursor = (attentionCursor + (forward ? 1 : n - 1)) % n
        }
        let it = items[attentionCursor]
        go(.thread(id: it.threadID, project: it.project))
        return it
    }

    private mutating func show(_ i: ShellInspector) {
        inspector = i
        lastInspector = i
    }
}

public extension MockSnapshot {
    func shellTask(_ id: String) -> (batch: MockBatch, task: MockTask)? {
        for b in batches {
            if let t = b.tasks.first(where: { $0.id == id || $0.threadID == id }) { return (b, t) }
        }
        return nil
    }
}

public struct ShellHUD: Equatable, Sendable {
    public var needsYou: Int
    public var stuck: Int
    public var running: Int
    public var machinesOK: Int
    public var machinesTotal: Int
    public var machinesHot: Int

    public init(needsYou: Int = 0, stuck: Int = 0, running: Int = 0, machinesOK: Int = 0, machinesTotal: Int = 0, machinesHot: Int = 0) {
        self.needsYou = needsYou; self.stuck = stuck; self.running = running
        self.machinesOK = machinesOK; self.machinesTotal = machinesTotal; self.machinesHot = machinesHot
    }

    public static func from(_ s: MockSnapshot) -> ShellHUD {
        var h = ShellHUD()
        for p in s.projects {
            let sum = s.summary(of: p)
            h.needsYou += sum.needsYou; h.stuck += sum.stuck; h.running += sum.running
        }
        h.machinesTotal = s.machines.count
        h.machinesOK = s.machines.filter { $0.ok && !$0.stale }.count
        h.machinesHot = s.machines.filter { $0.ok && $0.cpuNow >= 100 }.count
        return h
    }

    public var attention: Int { needsYou + stuck }

    public var attentionLabel: String {
        if attention == 0 { return "nada pendiente" }
        return attention == 1 ? "1 te necesita" : "\(attention) te necesitan"
    }
    public var runningLabel: String { "\(running) corriendo" }
    public var machinesLabel: String { machinesTotal == 0 ? "sin máquinas" : "\(machinesOK)/\(machinesTotal) máquinas" }
    public var machinesAlert: Bool { machinesOK < machinesTotal || machinesHot > 0 }
}

public struct ShellAttentionItem: Hashable, Sendable, Identifiable {
    public var threadID: String
    public var project: String
    public var title: String
    public var state: TaskState
    public var id: String { threadID }
}

public enum ShellAttention {
    public static func items(_ s: MockSnapshot) -> [ShellAttentionItem] {
        var out: [ShellAttentionItem] = []
        var seen = Set<String>()
        for p in s.projects.sorted() {
            for t in s.tasks(of: p) where (t.state == .needsYou || t.state == .stuck) && !seen.contains(t.id) {
                seen.insert(t.id)
                out.append(ShellAttentionItem(threadID: t.id, project: p, title: t.title, state: t.state))
            }
        }
        return out.enumerated().sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }.map(\.element)
    }
}

public struct ShellCommand: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case answer(threadID: String, project: String, option: String)
        case settle(threadID: String, project: String)
        case openT3(URL)
        case go(ShellTarget)
        case panel(ShellPanel)
        case nextAttention
        case cliOnly(String)
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var kind: Kind
    public var keywords: [String]
    public var attention: Bool

    public init(id: String, title: String, subtitle: String? = nil, kind: Kind, keywords: [String] = [], attention: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.kind = kind; self.keywords = keywords; self.attention = attention
    }

    public var group: String {
        switch kind {
        case .answer, .nextAttention: return "Te necesita"
        case .settle, .openT3: return "Hilos"
        case .go: return "Ir a"
        case .panel: return "Paneles"
        case .cliOnly: return "Solo CLI"
        }
    }
}

public enum ShellCommands {
    public static func all(_ s: MockSnapshot, selected: String? = nil) -> [ShellCommand] {
        var out: [ShellCommand] = []
        let attention = ShellAttention.items(s)
        if !attention.isEmpty {
            out.append(ShellCommand(id: "next-attention", title: "Siguiente que te necesita", subtitle: "\(attention.count) pendientes",
                                    kind: .nextAttention, keywords: ["atención", "pendiente", "siguiente"], attention: true))
        }
        var threads: [(MockTask, String)] = []
        for p in s.projects.sorted() { for t in s.tasks(of: p) { threads.append((t, p)) } }
        if let sel = selected, let i = threads.firstIndex(where: { $0.0.id == sel }) { threads.insert(threads.remove(at: i), at: 0) }

        for (t, p) in threads where t.state == .needsYou {
            if let q = t.question {
                for o in q.options {
                    out.append(ShellCommand(id: "answer:\(t.id):\(o)", title: "Responder «\(oneLine(q.summary, 60))» → \(o)",
                                            subtitle: "\(p) · \(oneLine(t.title, 50))", kind: .answer(threadID: t.id, project: p, option: o),
                                            keywords: ["responder", "answer", p, t.id, o], attention: true))
                }
            }
        }
        for (t, p) in threads {
            if t.state == .done || t.state == .stuck {
                out.append(ShellCommand(id: "settle:\(t.id)", title: "Settle «\(oneLine(t.title, 60))»", subtitle: "\(p) · cierra el hilo en T3 (no archiva)",
                                        kind: .settle(threadID: t.id, project: p), keywords: ["settle", "cerrar", p, t.id]))
            }
            if let u = t.link {
                out.append(ShellCommand(id: "t3:\(t.id)", title: "Abrir en T3 «\(oneLine(t.title, 60))»", subtitle: p, kind: .openT3(u),
                                        keywords: ["abrir", "t3", p, t.id]))
            }
        }
        for (t, p) in threads where t.state != .done && t.state != .skipped {
            out.append(ShellCommand(id: "go-thread:\(t.id)", title: "Ir al escritorio de «\(oneLine(t.title, 60))»", subtitle: p,
                                    kind: .go(.thread(id: t.id, project: p)), keywords: ["ir", "hilo", "escritorio", p, t.id],
                                    attention: t.state == .needsYou || t.state == .stuck))
        }
        out.append(ShellCommand(id: "go-city", title: "Ir a la ciudad", kind: .go(.city), keywords: ["ir", "ciudad", "todo"]))
        for p in s.projects.sorted() {
            let sum = s.summary(of: p)
            out.append(ShellCommand(id: "go:\(p)", title: "Ir a \(p)", subtitle: ProjectSummaryText.line(sum), kind: .go(.project(p)),
                                    keywords: ["ir", "proyecto", "piso", p], attention: sum.needsYou + sum.stuck > 0))
        }
        for panel in ShellPanel.allCases {
            out.append(ShellCommand(id: "panel:\(panel.rawValue)", title: "Panel \(panel.title)", kind: .panel(panel), keywords: ["panel", "ver"]))
        }
        for p in s.projects.sorted() {
            out.append(ShellCommand(id: "cli-fanout:\(p)", title: "Lanzar hilos en \(p) (fanout)", subtitle: "solo CLI: copia el comando",
                                    kind: .cliOnly("chopshop fanout \(p) --task \"…\""), keywords: ["lanzar", "launch", "fanout", "nuevo", p]))
        }
        for b in s.batches where b.id != SnapshotMapper.looseBatch
            && b.tasks.contains(where: { $0.state == .running || $0.state == .queued || $0.state == .waitingBot }) {
            out.append(ShellCommand(id: "cli-stop:\(b.id)", title: "Parar el lote \(b.id)", subtitle: "\(b.project) · solo CLI: copia el comando",
                                    kind: .cliOnly("chopshop stop \(b.id)"), keywords: ["parar", "stop", "detener", b.project, b.id]))
        }
        for g in s.graphs where !g.id.hasPrefix(SnapshotMapper.autoGraphPrefix) {
            out.append(ShellCommand(id: "cli-graph:\(g.id)", title: "Correr el grafo \(g.id)", subtitle: "\(g.project) · solo CLI: copia el comando",
                                    kind: .cliOnly("chopshop graph run \(g.id)"), keywords: ["grafo", "graph", "run", "correr", g.project, g.id]))
        }
        return out
    }

    public static func search(_ query: String, in commands: [ShellCommand], limit: Int = 40) -> [ShellCommand] {
        let q = fold(query).filter { !$0.isWhitespace }
        guard !q.isEmpty else { return Array(commands.prefix(limit)) }
        var scored: [(Int, Int, ShellCommand)] = []
        for (i, c) in commands.enumerated() {
            let hay = ([c.title] + c.keywords + [c.subtitle ?? ""]).joined(separator: " ")
            if let sc = score(q, in: fold(hay)) { scored.append((sc + (c.attention ? 1 : 0), i, c)) }
        }
        return scored.sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }.prefix(limit).map(\.2)
    }

    static func score(_ q: String, in hay: String) -> Int? {
        let h = Array(hay), n = Array(q)
        guard let first = n.first else { return 0 }
        var best: Int?
        for start in h.indices where h[start] == first {
            var i = 0, total = 0, run = 0
            var k = start
            while k < h.count, i < n.count {
                if h[k] == n[i] {
                    let prev: Character = k == 0 ? " " : h[k - 1]
                    var s = 1
                    if !prev.isLetter && !prev.isNumber { s += 6 }
                    if run > 0 { s += 3 * run }
                    total += s; run += 1; i += 1
                } else {
                    run = 0
                }
                k += 1
            }
            if i == n.count { best = max(best ?? total, total) } else { break }
        }
        return best
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es")).lowercased()
    }

    static func oneLine(_ s: String, _ n: Int) -> String {
        let l = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return l.count > n ? String(l.prefix(n - 1)) + "…" : l
    }
}

public enum ProjectSummaryText {
    public static func line(_ s: ProjectSummary) -> String {
        var parts: [String] = []
        if s.needsYou > 0 { parts.append("\(s.needsYou) \(s.needsYou == 1 ? "te necesita" : "te necesitan")") }
        if s.stuck > 0 { parts.append("\(s.stuck) \(s.stuck == 1 ? "trabada" : "trabadas")") }
        if s.running > 0 { parts.append("\(s.running) corriendo") }
        return parts.isEmpty ? "en calma" : parts.joined(separator: " · ")
    }
}

public enum ShellAction: String, CaseIterable, Sendable {
    case palette, nextAttention, prevAttention
    case panelAttention, panelActivity, panelBatches, panelReactions, panelMachineRoom, panelMachines
    case toggleInspector, toggleMinimap, openInT3, refresh, escape

    public var panel: ShellPanel? {
        switch self {
        case .panelAttention: return .attention
        case .panelActivity: return .activity
        case .panelBatches: return .batches
        case .panelReactions: return .reactions
        case .panelMachineRoom: return .machineRoom
        case .panelMachines: return .machines
        default: return nil
        }
    }
}

public struct ShellShortcut: Hashable, Sendable {
    public var action: ShellAction
    public var key: String
    public var shift: Bool
    public var title: String

    public init(_ action: ShellAction, _ key: String, shift: Bool = false, _ title: String) {
        self.action = action; self.key = key; self.shift = shift; self.title = title
    }

    public var command: Bool { key != "esc" }

    public var display: String {
        if key == "esc" { return "Esc" }
        return (shift ? "⇧" : "") + "⌘" + key.uppercased()
    }
}

public enum ShellKeymap {
    public static let all: [ShellShortcut] = [
        ShellShortcut(.palette, "k", "Paleta de órdenes"),
        ShellShortcut(.nextAttention, "j", "Siguiente que te necesita"),
        ShellShortcut(.prevAttention, "j", shift: true, "Anterior que te necesita"),
        ShellShortcut(.panelAttention, "1", "Panel Atención"),
        ShellShortcut(.panelActivity, "2", "Panel Actividad"),
        ShellShortcut(.panelBatches, "3", "Panel Lotes"),
        ShellShortcut(.panelReactions, "4", "Panel Reacciones"),
        ShellShortcut(.panelMachineRoom, "5", "Panel Sala de máquinas"),
        ShellShortcut(.panelMachines, "6", "Panel Máquinas"),
        ShellShortcut(.toggleInspector, "\\", "Mostrar u ocultar el panel"),
        ShellShortcut(.toggleMinimap, "m", shift: true, "Mostrar u ocultar el minimapa"),
        ShellShortcut(.openInT3, "o", "Abrir en T3 el hilo elegido"),
        ShellShortcut(.refresh, "r", "Actualizar"),
        ShellShortcut(.escape, "esc", "Cerrar la paleta; si no, el panel; si no, salir del piso (lo hace el mundo)"),
    ]

    public static func shortcut(for a: ShellAction) -> ShellShortcut? { all.first { $0.action == a } }
}

public struct ShellMinimap: Equatable, Sendable {
    public struct Block: Equatable, Sendable, Identifiable {
        public var company: String
        public var rect: CGRect
        public var floors: [Floor]
        public var id: String { company }
    }
    public struct Floor: Equatable, Sendable {
        public var project: String
        public var status: CityFloorStatus
        public var isLobby: Bool
    }

    public var blocks: [Block]

    public static func layout(_ m: CityModel, size: CGSize, inset: Double = 6) -> ShellMinimap {
        guard !m.buildings.isEmpty, size.width > 2 * inset, size.height > 2 * inset else { return ShellMinimap(blocks: []) }
        let minX = m.buildings.map(\.x0).min()!, minY = m.buildings.map(\.y0).min()!
        let maxX = m.buildings.map(\.x1).max()!, maxY = m.buildings.map(\.y1).max()!
        let w = max(1e-6, maxX - minX), h = max(1e-6, maxY - minY)
        let k = min((size.width - 2 * inset) / w, (size.height - 2 * inset) / h)
        let ox = (size.width - w * k) / 2, oy = (size.height - h * k) / 2
        let blocks = m.buildings.map { b in
            Block(company: b.company,
                  rect: CGRect(x: ox + (b.x0 - minX) * k, y: oy + (b.y0 - minY) * k, width: b.w * k, height: b.d * k),
                  floors: b.floors.map { Floor(project: $0.project, status: $0.status, isLobby: $0.isLobby) })
        }
        return ShellMinimap(blocks: blocks)
    }

    public func project(at p: CGPoint) -> String? {
        guard let b = blocks.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) else { return nil }
        let real = b.floors.filter { !$0.isLobby }
        return (real.last { $0.status != .neutral } ?? real.first)?.project
    }
}
