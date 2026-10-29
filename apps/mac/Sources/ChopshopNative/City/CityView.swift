import SwiftUI

/// Zoom fijo (capturas y vídeo): piso y progreso.
@available(macOS 26.0, *)
public struct CityFocus: Equatable, Sendable {
    public var project: String
    public var p: Double
    public init(project: String, p: Double) { self.project = project; self.p = p }
}

/// Estado mutable fuera de @State (no invalida la vista a 30 fps): último encuadre (para el clic) y escena de la oficina en caché.
@available(macOS 26.0, *)
final class CityViewBox {
    var cityFrame: IsoFrame?
    var sceneKey: LiveSceneKey?
    var cachedScene: IsoScene?
    var officeKey: OfficeSceneKey?
    var cachedOffice: IsoScene?
    var zoomGen = 0

    func scene(graph: MockGraph, tasks: [String: MockTask]) -> IsoScene {
        let k = LiveSceneKey(graph: graph, tasks: tasks)
        if let s = cachedScene, sceneKey == k { return s }
        let s = IsoScene(graph: graph, tasks: tasks)
        cachedScene = s; sceneKey = k
        return s
    }

    /// Piso de la oficina por escritorios (v3).
    func scene(office plan: OfficePlan, floor: Int) -> IsoScene {
        let k = OfficeSceneKey(plan: plan, floor: floor)
        if let s = cachedOffice, officeKey == k { return s }
        let s = IsoScene(office: plan, floor: floor)
        cachedOffice = s; officeKey = k
        return s
    }
}

/// La flota como ciudad isométrica: un edificio por empresa, un piso por proyecto (v3: uno por piso de su oficina, con el vestíbulo
/// en planta baja), una ventana encendida por hilo vivo.
/// Pisos en ámbar (te necesita) o rojo (trabada), barra "Atención" y leyenda. Clic en un piso → zoom continuo hasta ese piso, que
/// se convierte en la `IsoOfficeView` del proyecto (mismo encuadre, sin fundido). Esc o "Ciudad" vuelve.
@available(macOS 26.0, *)
public struct CityView: View {
    let model: CityModel
    let lights: CityLights
    let snapshot: MockSnapshot
    /// v3: oficinas por escritorios, por proyecto (los proyectos sin `office:` siguen con la oficina por rangos del grafo).
    var offices: [String: OfficePlan] = [:]
    var frozenTime: Double?
    var growth: Double?
    var frozenZoom: CityFocus?
    var flatChrome: Bool
    var onSelectFloor: ((String) -> Void)?

    @State private var box = CityViewBox()
    @State private var focus: String?
    /// Piso elegido (`CityFloor.id`) del proyecto enfocado.
    @State private var focusFloor: String?
    @State private var zoomFrom = 0.0
    @State private var zoomTo = 0.0
    @State private var zoomAt = -Double.infinity
    @State private var mounted = false
    @State private var showGraph = false
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    /// Duración del zoom completo en la app (la cronología grabada usa 5.6 s).
    public static let zoomDuration = 2.4

    /// Ciudad desde una proyección viva y sus ventanas (`CityLights`, que el llamador va alimentando con `observe`).
    public init(state: LiveState, lights: CityLights, directory: CompanyDirectory = .standard, onSelectFloor: ((String) -> Void)? = nil) {
        self.init(model: CityModel.build(state, directory: directory), lights: lights, snapshot: SnapshotMapper.snapshot(state),
                  offices: OfficePlan.all(state, directory: directory), onSelectFloor: onSelectFloor)
    }

    init(model: CityModel, lights: CityLights, snapshot: MockSnapshot, offices: [String: OfficePlan] = [:], frozenTime: Double? = nil,
         growth: Double? = nil, frozenZoom: CityFocus? = nil, flatChrome: Bool = false, onSelectFloor: ((String) -> Void)? = nil) {
        self.model = model; self.lights = lights; self.snapshot = snapshot; self.offices = offices; self.frozenTime = frozenTime; self.growth = growth
        self.frozenZoom = frozenZoom; self.flatChrome = flatChrome; self.onSelectFloor = onSelectFloor
    }

    // MARK: zoom

    private var target: String? { frozenZoom?.project ?? focus }

    private func progress(_ now: Double) -> Double {
        if let z = frozenZoom { return cityClamp(z.p) }
        let dur = Self.zoomDuration * max(0.05, abs(zoomTo - zoomFrom))
        return zoomFrom + (zoomTo - zoomFrom) * cityClamp((now - zoomAt) / dur)
    }

    private var officeMounted: Bool {
        if let z = frozenZoom { return z.p >= 1 && hasOffice(z.project) }
        return mounted && (focus.map(hasOffice) ?? false)
    }

    /// El piso se puede abrir: tiene oficina por escritorios (v3) o grafo (oficina por rangos).
    private func hasOffice(_ project: String) -> Bool { offices[project] != nil || graph(project) != nil }

    /// Piso de la oficina que se abre (el elegido en la ciudad o el primero).
    private func officeFloor(_ project: String) -> Int {
        focusFloor.flatMap { model.floor(id: $0) }.flatMap { $0.project == project ? $0.officeFloor : nil }
            ?? offices[project]?.floors.first?.index ?? 0
    }

    /// Escena de la oficina del proyecto (la misma que monta la vista al terminar el zoom).
    private func sceneFor(_ project: String) -> IsoScene? {
        if let plan = offices[project] { return box.scene(office: plan, floor: officeFloor(project)) }
        return graph(project).map { box.scene(graph: $0, tasks: tasks(project)) }
    }

    private func now() -> Double { frozenTime ?? Date().timeIntervalSinceReferenceDate }

    private func graph(_ project: String) -> MockGraph? { snapshot.graph(for: project) }
    private func tasks(_ project: String) -> [String: MockTask] {
        Dictionary(snapshot.tasks(of: project).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private func hosts(_ project: String) -> [String: String] {
        var d: [String: String] = [:]
        for b in snapshot.batches(of: project) { for t in b.tasks { d[t.id] = b.host } }
        return d
    }

    /// Clic en un piso (o en su aviso): `id` es el `CityFloor.id`; el vestíbulo abre la oficina del primer proyecto con oficina.
    private func select(_ id: String) {
        guard let project = model.project(ofFloor: id) else { return }
        onSelectFloor?(project)
        guard frozenZoom == nil, hasOffice(project) else { return }
        showGraph = false
        focusFloor = model.floor(id: id).flatMap { $0.lobby ? nil : $0.id }
        zoomIn(project)
    }

    private func zoomIn(_ project: String) {
        let t = now()
        let cur = focus == project ? progress(t) : 0
        focus = project; zoomFrom = cur; zoomTo = 1; zoomAt = t; mounted = false
        box.zoomGen += 1
        let gen = box.zoomGen
        let wait = Self.zoomDuration * (1 - cur)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            if box.zoomGen == gen { mounted = true }
        }
    }

    private func zoomOut() {
        let t = now()
        let cur = mounted ? 1 : progress(t)
        mounted = false; showGraph = false
        zoomFrom = cur; zoomTo = 0; zoomAt = t
        box.zoomGen += 1
        let gen = box.zoomGen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.zoomDuration * cur * 1_000_000_000))
            if box.zoomGen == gen { focus = nil; focusFloor = nil }
        }
    }

    private var zoomed: Bool { frozenZoom.map { $0.p > 0 } ?? (focus != nil && zoomTo > 0) }

    // MARK: cuerpo

    public var body: some View {
        Group {
            if officeMounted { content(p: 1, t: now(), office: true) }
            else if let t = frozenTime { content(p: progress(t), t: t, office: false) }
            else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { cx in
                    let t = cx.date.timeIntervalSinceReferenceDate
                    content(p: progress(t), t: t, office: false)
                }
            }
        }
    }

    private func content(p: Double, t: Double, office: Bool) -> some View {
        let ch = target == nil ? 0 : CityTransition.chrome(p)
        return VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .leading) {
                CityStatusLine(needsYou: model.needsYouCount, stuck: model.stuckCount, running: model.runningCount).opacity(CityTransition.chromeOut(ch))
                if let pr = target, ch > 0 { CityStatusLine(summary: snapshot.summary(of: pr)).opacity(CityTransition.chromeIn(ch)) }
            }
            card(p: p, t: t, office: office, chrome: ch)
        }
    }

    private func card(p: Double, t: Double, office: Bool, chrome ch: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0) {
            header(t: t, chrome: ch)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ZStack(alignment: .top) {
                // el grafo primero: con la oficina montada, "Grafo" también tiene que verse
                if showGraph, let pr = graphProject, let g = graph(pr) {
                    GraphView(graph: g, tasks: tasks(pr), hostOf: hosts(pr), frozenTime: frozenTime, flatChrome: flatChrome)
                } else if office, let pr = target, let plan = offices[pr] {
                    DeskOfficeView(plan: plan, tasks: tasks(pr), floor: officeFloor(pr), frozenTime: frozenTime, flatChrome: flatChrome)
                } else if office, let pr = target, let g = graph(pr) {
                    IsoOfficeView(graph: g, tasks: tasks(pr), hostOf: hosts(pr), frozenTime: frozenTime, flatChrome: flatChrome)
                } else {
                    canvas(p: p, t: t)
                    overlay(p: p, chrome: ch)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { if showGraph { GraphBackdrop() } else { IsoBackdrop() } }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    /// Proyecto del grafo: el piso enfocado; si no, el primero que pide algo; si no, el primero.
    private var graphProject: String? {
        target ?? model.alerts.first { graph($0.project) != nil }?.project ?? model.floors.first { graph($0.project) != nil }?.project
    }

    private func litCount(_ t: Double) -> Int {
        model.floors.reduce(0) { $0 + lights.windows($1.id, t: t).filter { $0 > 0.5 }.count }
    }

    private func header(t: Double, chrome ch: Double) -> some View {
        let plan = target.flatMap { offices[$0] }
        let g = plan == nil ? target.flatMap(graph) : nil
        return HStack(alignment: .firstTextBaseline) {
            ZStack(alignment: .leading) {
                Text("Todas las empresas").opacity(CityTransition.chromeOut(ch))
                if let plan { Text("\(plan.company) · \(plan.project)").opacity(CityTransition.chromeIn(ch)) }
                else if let g { Text(g.goal).opacity(CityTransition.chromeIn(ch)) }
            }
            .font(.callout.weight(.medium))
            Spacer()
            ZStack(alignment: .trailing) {
                Text("\(litCount(t)) de \(model.threadCount) hilos").opacity(CityTransition.chromeOut(ch))
                if let plan {
                    let alive = plan.people.filter { $0.state.alive }.count
                    Text("\(alive) \(alive == 1 ? "hilo" : "hilos") · \(plan.floors.flatMap(\.desks).count) escritorios").opacity(CityTransition.chromeIn(ch))
                } else if let g { Text("\(g.threads) de \(g.threadBudget) hilos").opacity(CityTransition.chromeIn(ch)) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.trailing, 6)
            CitySwitch(first: ch > 0.5 ? "Oficina" : "Ciudad", graph: showGraph, zoomed: zoomed || mounted,
                       pickFirst: {
                           if showGraph { showGraph = false } else if zoomed || mounted { zoomOut() }
                       },
                       pickGraph: { if graphProject != nil { showGraph = true } })
        }
    }

    // MARK: lienzo

    private func zoomData(p: Double, size: CGSize) -> (CityZoom, IsoFrame)? {
        guard p > 0, let pr = target, let sc = sceneFor(pr), let b = model.building(of: pr) else { return nil }
        let picked = focusFloor.flatMap { model.floor(id: $0) }.flatMap { $0.project == pr ? $0 : nil }
        guard let f = picked ?? model.floor(pr), !sc.rooms.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for r in sc.rooms { minX = min(minX, r.x0); minY = min(minY, r.y0); maxX = max(maxX, r.x0 + r.w); maxY = max(maxY, r.y0 + r.d) }
        let emb = OfficeEmbedding(rooms: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), building: b, level: f.level)
        let office = OfficeFraming.frame(IsoBounds(minU: sc.minU, maxU: sc.maxU, minV: sc.minV, maxV: sc.maxV), size: size)
        let tr = CityTransition(city: CityFraming.frame(model.bounds, size: size), office: office, embedding: emb)
        return (CityZoom(project: pr, p: p, transition: tr, scene: sc, floorID: f.id), tr.camera(p))
    }

    private func canvas(p: Double, t: Double) -> some View {
        let dark = scheme == .dark
        let zoomScene: IsoScene? = (p > 0 ? target : nil).flatMap { sceneFor($0) }
        return Canvas { ctx, size in
            guard !model.buildings.isEmpty else { return }
            let cityF = CityFraming.frame(model.bounds, size: size)
            box.cityFrame = cityF
            let z = zoomData(p: p, size: size)
            CityRenderer(model: model, lights: lights, cam: z?.1 ?? cityF, dark: dark, t: t, growth: growth,
                         hovered: hovered, zoom: z?.0, size: size, epoch: frozenTime == nil ? Date().timeIntervalSince1970 : nil).draw(&ctx)
        } symbols: {
            ForEach(model.floors) { f in
                CityFloorPill(name: f.label, tint: lights.tint(f.id, t: t)).tag("cf:\(f.id)")
            }
            ForEach(model.buildings) { b in
                CityCompanyTag(name: b.company, threads: b.floors.reduce(0) { $0 + $1.activeThreads.count }).tag("cb:\(b.company)")
            }
            if let sc = zoomScene {
                // mismas etiquetas que IsoOfficeView (el piso acaba siendo esa oficina)
                ForEach(sc.desks) { d in
                    if sc.focusFades {
                        IsoDeskLabel(label: d.node.label, visual: d.visual).tag("d:\(d.id)")
                    } else if d.person || d.sleeping {
                        OfficePersonLabel(name: d.person ? d.node.label : "dormido", subtitle: d.person ? d.node.title : nil, visual: d.visual)
                            .tag("d:\(d.id)")
                    }
                }
                ForEach(sc.rooms, id: \.index) { r in
                    IsoRoomLabel(text: r.label).tag("r:\(r.index)")
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                // solo con la ciudad quieta (p = 0): durante el zoom de vuelta el encuadre no es el de la ciudad
                let h = (zoomed || p > 0 || frozenTime != nil) ? nil : box.cityFrame.flatMap { CityHit.floor(at: pt, in: model, frame: $0) }
                if h != hovered { hovered = h }
            case .ended: hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { e in
            guard !zoomed, p == 0, let f = box.cityFrame, let id = CityHit.floor(at: e.location, in: model, frame: f) else { return }
            select(id)
        })
    }

    private func overlay(p: Double, chrome ch: Double) -> some View {
        let cityAlerts = model.alerts.map {
            IsoAlert(id: $0.id, label: model.floor(id: $0.id)?.label ?? $0.project, title: $0.title, visual: $0.status == .needsYou ? .needsYou : .stuck)
        }
        let officeAlerts: [IsoAlert]
        if let pr = target, let plan = offices[pr] {
            officeAlerts = plan.alerts(floor: officeFloor(pr)).map {
                IsoAlert(id: $0.id, label: $0.person?.name ?? $0.role, title: $0.person?.subtitle ?? $0.id, visual: $0.state.visual)
            }
        } else {
            officeAlerts = target.flatMap { pr in graph(pr).map { Self.officeAlerts(box.scene(graph: $0, tasks: tasks(pr)), tasks: tasks(pr)) } } ?? []
        }
        return ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .top) {
                if !cityAlerts.isEmpty && ch < 1 {
                    IsoAttentionBar(items: cityAlerts, selected: nil, flat: flatChrome) { id in select(id) }
                        .padding(.top, 12).opacity(CityTransition.chromeOut(ch)).allowsHitTesting(p == 0)
                }
                // la barra que tendrá la oficina, en el mismo sitio (al montarse IsoOfficeView no cambia nada)
                if !officeAlerts.isEmpty && ch > 0 {
                    IsoAttentionBar(items: officeAlerts, selected: nil, flat: flatChrome) { _ in }
                        .padding(.top, 12).opacity(CityTransition.chromeIn(ch)).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            CityLegend().padding(.leading, 18).padding(.bottom, 14).opacity(CityTransition.chromeOut(ch))
        }
        .animation(.spring(duration: 0.5, bounce: 0.22), value: cityAlerts.map(\.id))
    }

    /// Lo mismo que muestra la barra de IsoOfficeView sin nada seleccionado.
    static func officeAlerts(_ sc: IsoScene, tasks: [String: MockTask]) -> [IsoAlert] {
        sc.desks.filter { $0.visual == .needsYou || $0.visual == .stuck }
            .sorted { ($0.visual == .needsYou ? 0 : 1, $0.id) < ($1.visual == .needsYou ? 0 : 1, $1.id) }
            .map { IsoAlert(id: $0.id, label: $0.node.label, title: $0.node.task.flatMap { tasks[$0]?.title } ?? $0.node.title, visual: $0.visual) }
    }
}

// MARK: - Piezas

/// "1 decisión te espera · 1 tarea trabada · 29 corriendo" (como la frase de la vista de proyecto).
@available(macOS 26.0, *)
struct CityStatusLine: View {
    let needsYou: Int, stuck: Int, running: Int
    init(needsYou: Int, stuck: Int, running: Int) { self.needsYou = needsYou; self.stuck = stuck; self.running = running }
    init(summary s: ProjectSummary) { self.init(needsYou: s.needsYou, stuck: s.stuck, running: s.running) }

    var body: some View {
        var t = Text("")
        var first = true
        func add(_ s: String, _ c: Color?) {
            if !first { t = Text("\(t)\(Text("   ·   ").foregroundStyle(Color.secondary.opacity(0.5)))") }
            t = Text("\(t)\(Text(s).foregroundStyle(c ?? Color.secondary))"); first = false
        }
        if needsYou > 0 { add("\(needsYou) \(needsYou == 1 ? "decisión te espera" : "decisiones te esperan")", Attention.needsYou) }
        if stuck > 0 { add("\(stuck) \(stuck == 1 ? "tarea trabada" : "tareas trabadas")", Attention.stuck) }
        if running > 0 { add("\(running) corriendo", nil) }
        if first { add("Todo en calma", nil) }
        return t.font(.title3.weight(.semibold))
    }
}

/// Selector Ciudad (u Oficina, con el zoom dentro) | Grafo. Dibujado a mano: se ve igual en la app y en capturas.
@available(macOS 26.0, *)
struct CitySwitch: View {
    let first: String
    let graph: Bool
    let zoomed: Bool
    let pickFirst: () -> Void
    let pickGraph: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            segment(first, on: !graph, action: pickFirst)
                .keyboardShortcut(zoomed || graph ? KeyboardShortcut(.escape, modifiers: []) : nil)
            segment("Grafo", on: graph, action: pickGraph)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 3)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.95))
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    }
                }
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 26.0, *)
struct CityLegend: View {
    var body: some View {
        HStack(spacing: 18) {
            key(Color(white: 0.9), "corriendo")
            key(Attention.needsYou, "te necesita")
            key(Attention.stuck, "trabada")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
    private func key(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 6) { Circle().fill(c).frame(width: 7, height: 7); Text(s) }
    }
}

/// Píldora con el nombre del proyecto junto a su piso (ámbar/rojo si el piso pide algo).
@available(macOS 26.0, *)
struct CityFloorPill: View {
    let name: String
    let tint: (amber: Double, red: Double)
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let c: Color? = tint.amber > 0.5 ? Attention.needsYou : (tint.red > 0.5 ? Attention.stuck : nil)
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(scheme == .dark ? Color(white: 0.07).opacity(0.92) : Color.white.opacity(0.9)))
            .overlay(Capsule().strokeBorder(c ?? Color.primary.opacity(0.25), lineWidth: 0.8))
            .foregroundStyle(c ?? Color.primary.opacity(0.9))
    }
}

/// "PERSONAL · 11 hilos" sobre la azotea.
@available(macOS 26.0, *)
struct CityCompanyTag: View {
    let name: String
    let threads: Int
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("\(name.uppercased())  ·  \(threads) \(threads == 1 ? "hilo" : "hilos")")
            .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.6)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(scheme == .dark ? Color(white: 0.07).opacity(0.92) : Color.white.opacity(0.9)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.7))
            .foregroundStyle(Color.primary.opacity(0.75))
    }
}

/// Etiqueta de escritorio: el mismo estilo que los símbolos "d:" de IsoOfficeView.
@available(macOS 26.0, *)
struct IsoDeskLabel: View {
    let label: String
    let visual: NodeVisual
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.78)))
            .overlay(Capsule().strokeBorder(visual.tint?.opacity(0.9) ?? Color.primary.opacity(0.14), lineWidth: 0.7))
            .foregroundStyle(visual.tint ?? Color.primary.opacity(0.85))
    }
}

/// Etiqueta de sala: el mismo estilo que los símbolos "r:" de IsoOfficeView.
@available(macOS 26.0, *)
struct IsoRoomLabel: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(scheme == .dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
            .foregroundStyle(Color.primary.opacity(0.75))
    }
}

// MARK: - En vivo

/// Ciudad en vivo (macOS 26): la flota del `LiveStore` (el mismo estado que pinta la oficina). `onSelectFloor` recibe el proyecto
/// del piso pulsado (la vista ya hace el zoom a su oficina). La app la abrirá desde la barra lateral; el banco de pruebas, desde la
/// escena "Ciudad".
@available(macOS 26.0, *)
public struct LiveCityScreen: View {
    @ObservedObject var store: LiveStore
    let directory: CompanyDirectory
    let onSelectFloor: ((String) -> Void)?
    @State private var model = CityModel(buildings: [], groundX: 1, groundY: 1)
    @State private var offices: [String: OfficePlan] = [:]
    @State private var lights = CityLights()

    public init(store: LiveStore, directory: CompanyDirectory = .standard, onSelectFloor: ((String) -> Void)? = nil) {
        self.store = store; self.directory = directory; self.onSelectFloor = onSelectFloor
    }

    public var body: some View {
        Group {
            if model.buildings.isEmpty {
                VStack(spacing: 8) {
                    if case .connecting = store.status { ProgressView().controlSize(.small) }
                    Text("La ciudad se levanta sola cuando lleguen proyectos.").font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CityView(model: model, lights: lights, snapshot: store.snapshot, offices: offices, onSelectFloor: onSelectFloor)
                    .padding(.horizontal, 26).padding(.vertical, 22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Ciudad")
        .navigationSubtitle("\(model.buildings.count) empresas · \(model.projectCount) proyectos")
        .toolbar { ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: store.snapshot.machines) } }
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
    }

    private func refresh() {
        let m = CityModel.build(store.state, directory: directory)
        lights.observe(m, at: Date().timeIntervalSinceReferenceDate)
        if m != model { model = m }
        let o = OfficePlan.all(store.state, directory: directory)
        if o != offices { offices = o }
    }
}

#if NATIVE_PREVIEWS
#Preview("Ciudad · fixture · oscuro", traits: .fixedLayout(width: 1400, height: 900)) {
    let tl = CityTimeline.bundled()
    let f = tl.frame(at: 12)
    return CityView(model: f.model, lights: f.lights, snapshot: SnapshotMapper.snapshot(f.state), frozenTime: 12)
        .padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
}
#endif
