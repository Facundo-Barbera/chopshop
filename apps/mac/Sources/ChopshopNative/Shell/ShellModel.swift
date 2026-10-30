import Foundation
import CoreGraphics

// Armazón de la oficina (docs/plans/office-first-ui.md): lo que va ENCIMA del mundo. Puro (sin SwiftUI, macOS 13): HUD, paneles,
// paleta de órdenes con búsqueda difusa, atajos, ciclo de atención y minimapa. La vista (`OfficeShell.swift`, macOS 26) solo pinta
// esto y traduce las órdenes a acciones de la app.

// MARK: - Objetivos y paneles

/// Lo que se puede elegir en el mundo o pedirle que enfoque.
public enum ShellTarget: Hashable, Sendable {
    /// Toda la ciudad (salir del piso).
    case city
    /// El piso (o pisos) de un proyecto.
    case project(String)
    /// Un hilo (el escritorio que ocupa); `project` para que el mundo sepa a qué piso ir.
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

/// Petición del armazón al mundo: ir a `target`. `token` sube en cada petición (pedir dos veces lo mismo vuelve a hacer zoom).
public struct ShellFocus: Equatable, Sendable {
    public var target: ShellTarget
    public var token: Int
    public init(target: ShellTarget, token: Int) { self.target = target; self.token = token }
}

/// Lo que el armazón le da al mundo: adónde ir, si el Esc es suyo y cómo avisar de lo que el usuario elige.
public struct ShellWorldContext {
    public var focus: ShellFocus?
    /// No hay paleta ni panel abiertos: el Esc es del mundo (salir del piso).
    public var ownsEscape: Bool
    public var select: (ShellTarget) -> Void
    public var back: Int
    public init(focus: ShellFocus?, ownsEscape: Bool, back: Int = 0, select: @escaping (ShellTarget) -> Void) {
        self.focus = focus; self.ownsEscape = ownsEscape; self.back = back; self.select = select
    }
}

/// Paneles fijos del inspector: lo que eran pantallas aparte (Preguntas, Actividad, Lotes, Reacciones, Sala de máquinas, Máquinas).
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

/// Lo que muestra el inspector: un panel fijo o el detalle de lo elegido en el mundo.
public enum ShellInspector: Hashable, Sendable {
    case panel(ShellPanel)
    case target(ShellTarget)
}

// MARK: - Estado del armazón

/// Estado de los controles encima del mundo. Todas las transiciones son funciones puras (las prueba `ShellModelTests`).
public struct ShellState: Equatable, Sendable {
    public var inspector: ShellInspector?
    /// Último contenido del inspector (⌘\ lo vuelve a abrir tal cual).
    public var lastInspector: ShellInspector = .panel(.attention)
    public var paletteOpen = false
    public var query = ""
    public var minimap = true
    public var focus: ShellFocus?
    /// Hilo elegido (⌘O lo abre en T3).
    public var selectedThread: String?
    /// Posición en la lista de atención para ⌘J / ⇧⌘J (-1 = todavía ninguna).
    public var attentionCursor = -1
    public var backToken = 0

    public init() {}

    /// El usuario pulsó algo en el mundo: se abre su detalle (sin mover la cámara: ya está ahí).
    public mutating func select(_ target: ShellTarget) {
        if target == .city { selectedThread = nil; return }
        if case .project = target {
            selectedThread = nil
            if case .target = inspector { inspector = nil }
            return
        }
        selectedThread = target.threadID
        show(.target(target))
    }

    public mutating func attentionArrived() {
        if inspector == nil { show(.panel(.attention)) }
    }

    /// La paleta, el minimapa o ⌘J piden ir a algo: el mundo hace zoom y el inspector muestra su detalle.
    public mutating func go(_ target: ShellTarget) {
        focus = ShellFocus(target: target, token: (focus?.token ?? 0) + 1)
        if target == .city { selectedThread = nil; return }
        select(target)
    }

    /// ⌘1…⌘6: abre ese panel; si ya está abierto, lo cierra.
    public mutating func toggle(_ panel: ShellPanel) {
        if inspector == .panel(panel) { inspector = nil } else { show(.panel(panel)) }
    }

    /// ⌘\: muestra u oculta el inspector (al volver, con lo último que tenía).
    public mutating func toggleInspector() {
        if inspector == nil { inspector = lastInspector } else { inspector = nil }
    }

    public mutating func openPalette() { paletteOpen = true; query = "" }
    public mutating func closePalette() { paletteOpen = false; query = "" }

    /// Esc: cierra la paleta; si no, el inspector. `false` = no había nada que cerrar (el Esc es del mundo: salir del piso).
    @discardableResult
    public mutating func escape() -> Bool {
        if paletteOpen { closePalette(); return true }
        if inspector != nil { inspector = nil; return true }
        return false
    }

    public mutating func back() { backToken += 1 }

    public mutating func escapeOrBack() {
        if !escape() { back() }
    }

    /// ⌘J / ⇧⌘J: siguiente (o anterior) hilo que te necesita, en el orden de `ShellAttention.items`. Va al hilo y abre su detalle.
    /// Devuelve el elegido (nil si no hay nada pendiente).
    @discardableResult
    public mutating func cycleAttention(_ items: [ShellAttentionItem], forward: Bool = true) -> ShellAttentionItem? {
        guard !items.isEmpty else { attentionCursor = -1; return nil }
        // si la lista cambió y el hilo elegido sigue en ella, se sigue desde él
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

// MARK: - Búsqueda en el snapshot

public extension MockSnapshot {
    /// La tarea y su lote por id de tarea o por hilo de T3 (el mundo elige escritorios por hilo; el snapshot va por tarea).
    func shellTask(_ id: String) -> (batch: MockBatch, task: MockTask)? {
        for b in batches {
            if let t = b.tasks.first(where: { $0.id == id || $0.threadID == id }) { return (b, t) }
        }
        return nil
    }
}

// MARK: - HUD

/// Los tres contadores de la barra: te necesita (ámbar/rojo), corriendo y máquinas.
public struct ShellHUD: Equatable, Sendable {
    public var needsYou: Int
    public var stuck: Int
    public var running: Int
    public var machinesOK: Int
    public var machinesTotal: Int
    /// Máquinas con la CPU al 100 % o más (el HUD las marca).
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
    /// El contador de máquinas pide atención (alguna caída o saturada).
    public var machinesAlert: Bool { machinesOK < machinesTotal || machinesHot > 0 }
}

// MARK: - Atención

public struct ShellAttentionItem: Hashable, Sendable, Identifiable {
    public var threadID: String
    public var project: String
    public var title: String
    public var state: TaskState
    public var id: String { threadID }
}

public enum ShellAttention {
    /// Lo que te necesita, primero las decisiones y luego lo trabado; dentro, por proyecto y en el orden de los lotes.
    public static func items(_ s: MockSnapshot) -> [ShellAttentionItem] {
        var out: [ShellAttentionItem] = []
        var seen = Set<String>()
        for p in s.projects.sorted() {
            for t in s.tasks(of: p) where (t.state == .needsYou || t.state == .stuck) && !seen.contains(t.id) {
                seen.insert(t.id)
                out.append(ShellAttentionItem(threadID: t.id, project: p, title: t.title, state: t.state))
            }
        }
        // orden estable: needsYou < stuck, y el resto como venía
        return out.enumerated().sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }.map(\.element)
    }
}

// MARK: - Paleta de órdenes

public struct ShellCommand: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `POST /answer` con esa opción.
        case answer(threadID: String, project: String, option: String)
        /// `POST /settle` (cierra el hilo en T3, nunca archiva).
        case settle(threadID: String, project: String)
        case openT3(URL)
        case go(ShellTarget)
        case panel(ShellPanel)
        case nextAttention
        /// Sin ruta en el agente (todavía): copia el comando de la CLI al portapapeles.
        case cliOnly(String)
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var kind: Kind
    /// Palabras extra para la búsqueda (verbo, proyecto, id del hilo).
    public var keywords: [String]
    /// Se pinta con el color de atención (solo responder y lo trabado).
    public var attention: Bool

    public init(id: String, title: String, subtitle: String? = nil, kind: Kind, keywords: [String] = [], attention: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.kind = kind; self.keywords = keywords; self.attention = attention
    }

    /// Grupo en la paleta sin búsqueda.
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
    /// Todas las órdenes posibles con este snapshot. `selected` (el hilo elegido) va primero en settle / abrir en T3.
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
        // el lote «(sueltas)» y los grafos sintéticos los inventa el cliente: la CLI no los conoce
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

    /// Búsqueda difusa: cada carácter de la consulta en orden (subsecuencia), sin mayúsculas ni tildes. Puntúa más los aciertos
    /// al principio de palabra y seguidos; con empate, el orden de `all` (atención primero). Consulta vacía = todo, tal cual.
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

    /// Puntuación de `q` (ya plegada, sin espacios) como subsecuencia de `hay`, o nil si no lo es. Prueba cada aparición del
    /// primer carácter como inicio (con avance voraz desde ahí) y se queda con la mejor: «lo» en «panel lotes» puntúa por «lotes».
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
                    if !prev.isLetter && !prev.isNumber { s += 6 }      // principio de palabra
                    if run > 0 { s += 3 * run }                          // seguidos
                    total += s; run += 1; i += 1
                } else {
                    run = 0
                }
                k += 1
            }
            if i == n.count { best = max(best ?? total, total) } else { break }   // si desde aquí no cabe, desde más allá tampoco
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

/// La misma frase corta que el subtítulo de la vista de proyecto, sin SwiftUI.
public enum ProjectSummaryText {
    public static func line(_ s: ProjectSummary) -> String {
        var parts: [String] = []
        if s.needsYou > 0 { parts.append("\(s.needsYou) \(s.needsYou == 1 ? "te necesita" : "te necesitan")") }
        if s.stuck > 0 { parts.append("\(s.stuck) \(s.stuck == 1 ? "trabada" : "trabadas")") }
        if s.running > 0 { parts.append("\(s.running) corriendo") }
        return parts.isEmpty ? "en calma" : parts.joined(separator: " · ")
    }
}

// MARK: - Atajos

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

/// Un atajo: tecla (un carácter, o "esc") con ⌘ (y ⇧ si `shift`). Esc va sin modificadores.
public struct ShellShortcut: Hashable, Sendable {
    public var action: ShellAction
    public var key: String
    public var shift: Bool
    public var title: String

    public init(_ action: ShellAction, _ key: String, shift: Bool = false, _ title: String) {
        self.action = action; self.key = key; self.shift = shift; self.title = title
    }

    public var command: Bool { key != "esc" }

    /// Como se escribe en el menú y en docs/plans/office-first-ui.md: «⇧⌘J», «⌘K», «Esc».
    public var display: String {
        if key == "esc" { return "Esc" }
        return (shift ? "⇧" : "") + "⌘" + key.uppercased()
    }
}

/// Fuente única de los atajos del armazón: el menú «Oficina» se genera de aquí y `apps/mac/tests/test_office_first_ui.py`
/// comprueba que la tabla «Atajos» del plan coincide. Una entrada por línea (el test las lee con una expresión regular).
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
        ShellShortcut(.escape, "esc", "Cerrar la paleta; si no, el panel; si no, subir un nivel (piso, edificio, campus, ciudad)"),
    ]

    public static func shortcut(for a: ShellAction) -> ShellShortcut? { all.first { $0.action == a } }
}

// MARK: - Minimapa

/// Planta de la ciudad vista desde arriba, escalada a un rectángulo: un bloque por edificio y una franja por piso (las que piden algo
/// llevan el color de atención). Clic en un bloque → ir a ese proyecto (el piso de arriba con atención, si no el primero).
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

    /// `size`: tamaño del minimapa en puntos; `inset`: margen interior.
    public static func layout(_ m: CityModel, size: CGSize, inset: Double = 6) -> ShellMinimap {
        guard !m.buildings.isEmpty, size.width > 2 * inset, size.height > 2 * inset else { return ShellMinimap(blocks: []) }
        let minX = m.buildings.map(\.x0).min()!, minY = m.buildings.map(\.y0).min()!
        let maxX = m.buildings.map(\.x1).max()!, maxY = m.buildings.map(\.y1).max()!
        let w = max(1e-6, maxX - minX), h = max(1e-6, maxY - minY)
        let k = min((size.width - 2 * inset) / w, (size.height - 2 * inset) / h)
        let ox = (size.width - w * k) / 2, oy = (size.height - h * k) / 2
        let W = Double(size.width), H = Double(size.height), kk = Double(k), oxx = Double(ox), oyy = Double(oy)
        let minSide: Double = min(5.0, (W - 2 * inset) / 2, (H - 2 * inset) / 2)
        let blocks = m.buildings.map { b -> Block in
            let bw: Double = max(minSide, b.w * kk), bh: Double = max(minSide, b.d * kk)
            let cx: Double = oxx + (b.x0 + b.w / 2 - minX) * kk, cy: Double = oyy + (b.y0 + b.d / 2 - minY) * kk
            let x: Double = min(max(0, cx - bw / 2), W - bw), y: Double = min(max(0, cy - bh / 2), H - bh)
            return Block(company: b.company, rect: CGRect(x: x, y: y, width: bw, height: bh),
                         floors: b.floors.map { Floor(project: $0.project, status: $0.status, isLobby: $0.isLobby) })
        }
        return ShellMinimap(blocks: blocks)
    }

    /// Proyecto al pulsar en `p` (nil fuera de los bloques o en un edificio sin proyectos).
    public func project(at p: CGPoint) -> String? {
        guard let b = blocks.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) else { return nil }
        let real = b.floors.filter { !$0.isLobby }
        return (real.last { $0.status != .neutral } ?? real.first)?.project
    }
}
