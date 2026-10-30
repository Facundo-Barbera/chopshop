import SwiftUI
import AppKit

/// Zoom fijo (capturas y vídeo): piso y progreso.
@available(macOS 26.0, *)
public struct CityFocus: Equatable, Sendable {
    public var project: String
    public var p: Double
    /// `CityFloor.id` del piso (nil = el primero del proyecto).
    public var floor: String?
    public init(project: String, p: Double, floor: String? = nil) { self.project = project; self.p = p; self.floor = floor }
}

/// Estado mutable fuera de @State (no invalida la vista a 30 fps): último encuadre (para el clic) y escena de la oficina en caché.
@available(macOS 26.0, *)
final class CityViewBox {
    var cityFrame: IsoFrame?
    var sceneKey: LiveSceneKey?
    var cachedScene: IsoScene?
    var zoomGen = 0
    let ease = CityCameraEase()
    let cut = CityCutCamera()
    var outFrame: IsoFrame?
    private var layoutKey: (plan: FloorPlan, frame: FloorFrame)?
    private var cachedLayout: FloorLayout?
    var frameInWindow = CGRect.zero
    var scrollActive = false
    var onPull: ((Double, CGPoint) -> Void)?
    private var monitor: Any?
    private var pull = 0.0
    private var pullAt = 0.0
    private var blockedUntil = 0.0

    static let pullThreshold = 0.5
    static let pullWindow = 0.7
    static let pullCooldown = 0.9

    func scene(graph: MockGraph, tasks: [String: MockTask]) -> IsoScene {
        let k = LiveSceneKey(graph: graph, tasks: tasks)
        if let s = cachedScene, sceneKey == k { return s }
        let s = IsoScene(graph: graph, tasks: tasks)
        cachedScene = s; sceneKey = k
        return s
    }

    func layout(_ plan: FloorPlan, frame: FloorFrame) -> FloorLayout {
        if let k = layoutKey, let l = cachedLayout, k.frame == frame, k.plan == plan { return l }
        let l = FloorLayout(plan: plan, frame: frame)
        layoutKey = (plan, frame); cachedLayout = l
        return l
    }

    func installScrollMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.scrollActive, let win = e.window, let content = win.contentView else { return e }
            let loc = e.locationInWindow
            let p = CGPoint(x: loc.x, y: content.bounds.height - loc.y)
            guard self.frameInWindow.contains(p) else { return e }
            guard !e.hasPreciseScrollingDeltas || e.modifierFlags.contains(.command) else { return e }
            let dy = e.hasPreciseScrollingDeltas ? Double(e.scrollingDeltaY) * 0.01 : Double(e.scrollingDeltaY) * 0.12
            self.feed(dy, at: CGPoint(x: p.x - self.frameInWindow.minX, y: p.y - self.frameInWindow.minY))
            return nil
        }
    }

    func removeScrollMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    func feed(_ d: Double, at p: CGPoint) {
        guard d != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= blockedUntil else { return }
        if now - pullAt > Self.pullWindow || (pull > 0) != (d > 0) { pull = 0 }
        pullAt = now
        pull += d
        guard abs(pull) >= Self.pullThreshold, let f = onPull else { return }
        let dir = pull
        pull = 0
        blockedUntil = now + Self.pullCooldown
        f(dir, p)
    }
}

/// La flota como ciudad isométrica: un edificio por empresa, un piso por proyecto (v3: uno por piso de su `office`, ≤ 4, y el
/// vestíbulo en la planta baja), una ventana encendida por hilo vivo.
/// Pisos en ámbar (te necesita) o rojo (trabada), barra "Atención" y leyenda. Clic en un piso → zoom continuo hasta ese piso, y la
/// ciudad se queda: el edificio cortado a su altura con la oficina dentro (departamentos y escritorios del `office` tipado de
/// `LiveState`, a la escala de la huella). Un proyecto sin `office` (agente v2) sigue abriendo la `IsoOfficeView` del grafo. Esc o
/// "Ciudad" vuelve.
@available(macOS 26.0, *)
public struct CityView: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
    let model: CityModel
    let lights: CityLights
    let snapshot: MockSnapshot
    /// Proyección tipada de la que salen los pisos v3 (nil: solo grafo, como las cronologías sin `office`).
    let state: LiveState?
    var frozenTime: Double?
    /// Reloj de la semivida con la ciudad congelada (capturas); sin él, el reloj real.
    var frozenNow: Date?
    var growth: Double?
    var frozenZoom: CityFocus?
    var flatChrome: Bool
    var onSelectFloor: ((String) -> Void)?
    /// Hilo cuyo inspector se abre en un piso (cuenta como «tocar», `POST /touch`).
    var onInspect: ((String) -> Void)?
    /// Petición del armazón (paleta, minimapa, ⌘J): ir al piso de ese proyecto. Cada petición nueva trae otro `token`.
    var focusRequest: ShellFocus?
    var backRequest: Int
    /// Esc sale del piso (false mientras el armazón tiene la paleta o un panel abiertos: el Esc es suyo).
    var escapeZoomsOut = true

    @State private var box = CityViewBox()
    @State private var focus: String?
    /// `CityFloor.id` del piso enfocado (nil = el primero del proyecto).
    @State private var focusFloor: String?
    @State private var zoomFrom = 0.0
    @State private var zoomTo = 0.0
    @State private var zoomAt = -Double.infinity
    @State private var mounted = false
    @State private var hovered: String?
    @State private var campus: String?
    @State private var zoomOrigin: String?
    @State private var officeAll = false
    @State private var officeRegion: String?
    @Environment(\.colorScheme) private var scheme

    /// Duración del zoom completo en la app (la cronología grabada usa 5.6 s).
    public static let zoomDuration = 2.4

    static let demoTour = ProcessInfo.processInfo.environment["CHOPSHOP_DEMO_TOUR"] == "1"

    /// Ciudad desde una proyección viva y sus ventanas (`CityLights`, que el llamador va alimentando con `observe`).
    public init(state: LiveState, lights: CityLights, directory: CompanyDirectory = .standard, onSelectFloor: ((String) -> Void)? = nil,
                onInspect: ((String) -> Void)? = nil, focusRequest: ShellFocus? = nil, backRequest: Int = 0, escapeZoomsOut: Bool = true) {
        self.init(model: CityModel.build(state, directory: directory), lights: lights, snapshot: SnapshotMapper.snapshot(state),
                  state: state, onSelectFloor: onSelectFloor, onInspect: onInspect, focusRequest: focusRequest,
                  backRequest: backRequest, escapeZoomsOut: escapeZoomsOut)
    }

    init(model: CityModel, lights: CityLights, snapshot: MockSnapshot, state: LiveState? = nil, frozenTime: Double? = nil,
         frozenNow: Date? = nil, growth: Double? = nil, frozenZoom: CityFocus? = nil, flatChrome: Bool = false,
         onSelectFloor: ((String) -> Void)? = nil, onInspect: ((String) -> Void)? = nil, focusRequest: ShellFocus? = nil,
         backRequest: Int = 0, escapeZoomsOut: Bool = true) {
        self.model = model; self.lights = lights; self.snapshot = snapshot; self.state = state; self.frozenTime = frozenTime
        self.frozenNow = frozenNow; self.growth = growth; self.frozenZoom = frozenZoom; self.flatChrome = flatChrome
        self.onSelectFloor = onSelectFloor; self.onInspect = onInspect; self.focusRequest = focusRequest
        self.backRequest = backRequest; self.escapeZoomsOut = escapeZoomsOut
    }

    // MARK: zoom

    private var target: String? { frozenZoom?.project ?? focus }

    /// `CityFloor.id` del piso enfocado: el elegido o, si no, el primero del proyecto.
    private var targetFloor: String? {
        guard let pr = target else { return nil }
        let chosen = frozenZoom != nil ? frozenZoom?.floor : focusFloor
        return chosen ?? model.floor(pr)?.id
    }

    /// Piso v3 enfocado, del `office` tipado de la proyección (nil si el proyecto no lo trae).
    private var targetPlan: FloorPlan? { target.flatMap { plan($0, floor: targetFloor) } }

    private var shownPlan: FloorPlan? {
        guard let pr = target, let rid = officeRegion, officeMounted else { return targetPlan }
        return floors(pr).first { Self.regionID($0) == rid } ?? targetPlan
    }

    /// Pisos de la oficina del proyecto (`ProjectOffice`: los del perfil o, sin `office`, los sintéticos por rol, y el vestíbulo).
    private func floors(_ project: String) -> [FloorPlan] {
        state.map { ProjectOffice.floors(in: $0, project: project, now: officeNow ?? Date()) } ?? []
    }

    /// Índice (en `floors`) del piso pulsado; si no se sabe, el de escritorios más bajo, o el vestíbulo si no hay otro.
    private func floorIndex(_ project: String, floor id: String?, in all: [FloorPlan]) -> Int? {
        guard !all.isEmpty else { return nil }
        if let id, model.floor(id: id)?.isLobby == true, let l = all.firstIndex(where: { $0.kind == .lobby }) { return l }
        let idx = id.flatMap { model.floor(id: $0) }.flatMap { $0.isLobby ? nil : $0.floorIndex }
        return idx.flatMap { i in all.firstIndex { $0.kind != .lobby && $0.floorIndex == i } }
            ?? all.firstIndex { $0.kind != .lobby } ?? 0
    }

    /// Proyecto en el que entra un piso pulsado: el suyo; el del vestíbulo, si el edificio es de un solo proyecto.
    private func project(of fl: CityFloor) -> String? {
        guard fl.isLobby else { return fl.project }
        let ps = Set(model.buildings.first { $0.floors.contains { $0.id == fl.id } }?.floors.filter { !$0.isLobby }.map(\.project) ?? [])
        return ps.count == 1 ? ps.first : nil
    }

    private func plan(_ project: String, floor id: String?) -> FloorPlan? {
        let all = floors(project)
        return floorIndex(project, floor: id, in: all).map { all[$0] }
    }

    private static func regionID(_ plan: FloorPlan) -> String {
        plan.kind == .lobby ? "lobby:\(plan.name ?? "")" : "floor:\(plan.floorIndex)"
    }

    private func cityFloorID(_ plan: FloorPlan, project pr: String) -> String? {
        if plan.kind == .lobby, let l = model.building(of: pr)?.floors.first(where: { $0.isLobby }) { return l.id }
        return model.floors.first { $0.project == pr && !$0.isLobby && $0.floorIndex == plan.floorIndex }?.id ?? targetFloor
    }

    private func pickerItems(_ all: [FloorPlan]) -> [FloorPicker.Item] {
        let order = all.sorted { ($0.kind == .lobby ? 0 : 1, $0.floorIndex) < ($1.kind == .lobby ? 0 : 1, $1.floorIndex) }
        let lift = order.first?.kind == .lobby ? 0 : 1
        return order.enumerated().map { k, p in
            FloorPicker.Item(id: Self.regionID(p), label: p.kind == .lobby ? "PB" : "\(k + lift)", help: p.shortTitle.capitalized)
        }
    }

    private func goFloor(_ id: String) {
        officeRegion = id
        officeAll = false
    }

    private func stepFloor(_ d: Int) {
        guard let pr = target else { return }
        let items = pickerItems(floors(pr))
        let cur = shownPlan.map(Self.regionID)
        guard let i = items.firstIndex(where: { $0.id == cur }) else { return }
        let j = min(max(0, i + d), items.count - 1)
        if j != i { goFloor(items[j].id) }
    }

    private static func selection(ofSpot id: String, in plan: FloorPlan) -> String? {
        if FloorLayout.machinePart(id) != nil { return nil }
        if id.hasPrefix("lobby:") { return String(id.dropFirst(6)) }
        return plan.desk(id)?.occupant?.threadID
    }

    /// Hay algo que abrir: el piso v3 o, sin `office`, el grafo.
    private func canZoom(_ project: String) -> Bool { plan(project, floor: nil) != nil || graph(project) != nil }

    /// Reloj de la semivida del piso: fijo con la ciudad congelada, el real si no.
    private var officeNow: Date? { frozenNow ?? (frozenTime == nil ? nil : Date()) }

    private func progress(_ now: Double) -> Double {
        if let z = frozenZoom { return cityClamp(z.p) }
        let dur = Self.zoomDuration * max(0.05, abs(zoomTo - zoomFrom))
        return zoomFrom + (zoomTo - zoomFrom) * cityClamp((now - zoomAt) / dur)
    }

    private var officeMounted: Bool {
        if let z = frozenZoom { return z.p >= 1 && canZoom(z.project) }
        return mounted && focus.map(canZoom) == true
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

    /// `floor`: `CityFloor.id` del piso pulsado (nil = el primero del proyecto, p. ej. desde un aviso del vestíbulo).
    /// `notify: false` cuando lo pide el armazón (`focusRequest`): ya sabe adónde va y no hay que reabrirle el panel del piso.
    private func select(_ project: String, floor: String? = nil, notify: Bool = true) {
        if notify { onSelectFloor?(project) }
        guard frozenZoom == nil, canZoom(project) else { return }
        zoomIn(project, floor: floor)
    }

    private func zoomIn(_ project: String, floor: String?) {
        let t = now()
        let same = focus == project && focusFloor == floor
        let cur = same ? progress(t) : 0
        if !(same && cur > 0) { zoomOrigin = campusFocus }
        campus = model.campus(of: project) ?? campus
        officeAll = false
        officeRegion = nil
        box.outFrame = nil
        box.cut.reset()
        focus = project; focusFloor = floor; zoomFrom = cur; zoomTo = 1; zoomAt = t; mounted = false
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
        if cur >= 0.98 { zoomOrigin = campusFocus } else { campus = zoomOrigin }
        if officeIsWorld, let pr = target, let pl = shownPlan {
            focusFloor = cityFloorID(pl, project: pr)
            box.outFrame = box.cut.current
        }
        mounted = false
        officeAll = false
        officeRegion = nil
        zoomFrom = cur; zoomTo = 0; zoomAt = t
        box.zoomGen += 1
        let gen = box.zoomGen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.zoomDuration * cur * 1_000_000_000))
            if box.zoomGen == gen { focus = nil; focusFloor = nil }
        }
    }

    private var zoomed: Bool { frozenZoom.map { $0.p > 0 } ?? (focus != nil && zoomTo > 0) }

    private var campusFocus: String? { campus.flatMap { model.campus($0) == nil ? nil : $0 } }

    private var inOffice: Bool { frozenZoom == nil && (zoomed || mounted) }

    private var officeIsWorld: Bool { officeMounted && state != nil && targetPlan != nil }

    private var canStepOut: Bool { inOffice || campusFocus != nil }

    private func stepOut() {
        guard frozenZoom == nil else { return }
        if zoomed || mounted {
            zoomOut()
        } else if campusFocus != nil {
            campus = nil
        }
    }

    private func goCity() {
        guard frozenZoom == nil else { return }
        if zoomed || mounted { zoomOut() }
        campus = nil
    }

    private func goCampus(_ name: String) {
        guard frozenZoom == nil else { return }
        if zoomed || mounted { zoomOut() }
        campus = name
    }

    private func goBuilding() {
        guard officeIsWorld else { return }
        officeAll = true
        box.cut.fitBuilding()
    }

    private func levelFrame(_ size: CGSize, campus c: String?) -> IsoFrame {
        CityFraming.frame(c.flatMap { model.bounds(campus: $0) } ?? model.bounds, size: size)
    }

    private func pulled(_ dir: Double, at p: CGPoint) {
        guard frozenZoom == nil, !zoomed, !mounted else { return }
        if dir < 0 {
            if campusFocus != nil { campus = nil }
        } else if campusFocus == nil, let f = box.cityFrame, let c = CityHit.campus(at: p, in: model, frame: f) {
            campus = c
        }
    }

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
        .onAppear { if frozenTime == nil { box.installScrollMonitor() } }
        .onDisappear { box.removeScrollMonitor() }
        .onChange(of: focusRequest) { _, r in
            // `nil` (volver a la ciudad) o un proyecto: el zoom de siempre; un hilo cae en el piso de su proyecto
            guard let r else { return }
            if let pr = r.target.project {
                if pr != focus || !(zoomed || mounted) { select(pr, notify: false) }
            } else {
                goCity()
            }
        }
        .onChange(of: backRequest) { _, _ in stepOut() }
        .task(id: Self.demoTour ? tourStart()?.project : nil) { if Self.demoTour, frozenTime == nil, frozenZoom == nil { await tour() } }
        .hotReload()
    }

    private func tourStart() -> (project: String, floor: String)? {
        var best: (project: String, floor: String, n: Int)?
        for b in model.buildings {
            for fl in b.floors where !fl.isLobby {
                guard let pr = project(of: fl), canZoom(pr) else { continue }
                let all = floors(pr)
                let n = all.filter { $0.kind != .lobby }.count * 100 + all.reduce(0) { $0 + $1.desks.count }
                if n > (best?.n ?? 0) { best = (pr, fl.id, n) }
            }
        }
        return best.map { ($0.project, $0.floor) }
    }

    private func floorPosition() -> (i: Int, n: Int)? {
        guard let pr = target else { return nil }
        let items = pickerItems(floors(pr))
        let cur = shownPlan.map(Self.regionID)
        return items.firstIndex { $0.id == cur }.map { ($0, items.count) }
    }

    private func tour() async {
        func pause(_ s: Double) async -> Bool {
            (try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))) != nil
        }
        while !Task.isCancelled {
            guard await pause(2) else { return }
            guard let start = tourStart() else { continue }
            select(start.project, floor: start.floor)
            var waited = 0.0
            while !officeMounted && waited < Self.zoomDuration + 3 {
                guard await pause(0.1) else { return }
                waited += 0.1
            }
            guard await pause(4) else { return }
            while let pos = floorPosition(), pos.i < pos.n - 1 {
                stepFloor(1)
                guard await pause(2.5) else { return }
            }
            while let pos = floorPosition(), pos.i > 0 {
                stepFloor(-1)
                guard await pause(2.5) else { return }
            }
            goCity()
            guard await pause(Self.zoomDuration) else { return }
        }
    }

    private func content(p: Double, t: Double, office: Bool) -> some View {
        let ch = target == nil ? 0 : CityTransition.chrome(p)
        box.scrollActive = frozenTime == nil && !office && !zoomed && p == 0
        box.onPull = { dir, pt in pulled(dir, at: pt) }
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
                if office, let pr = target, state != nil, let plan = shownPlan {
                    cutStage(pr, plan: plan)
                } else if office, let pr = target, let g = graph(pr) {
                    IsoOfficeView(graph: g, tasks: tasks(pr), hostOf: hosts(pr), frozenTime: frozenTime, flatChrome: flatChrome)
                } else {
                    canvas(p: p, t: t)
                    overlay(p: p, chrome: ch)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frameInWindow = $0 }
        }
        .background(IsoBackdrop())
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func litCount(_ t: Double) -> Int {
        model.floors.reduce(0) { $0 + lights.windows($1.id, t: t).filter { $0 > 0.5 }.count }
    }

    /// Título y recuento del piso enfocado: nombre del piso y escritorios ocupados en v3; objetivo e hilos del grafo si no.
    private func officeHeader(now: Date) -> (title: String, count: String)? {
        guard let pr = target else { return nil }
        if let plan = shownPlan {
            let desks = plan.desks.filter { !$0.retired }
            let busy = desks.filter { plan.occupant(of: $0.id, now: now) != nil }.count
            return (plan.name.map { "\(pr) · \($0)" } ?? pr, "\(busy) de \(desks.count) escritorios")
        }
        return graph(pr).map { ($0.goal, "\($0.threads) de \($0.threadBudget) hilos") }
    }

    private func act(_ on: Bool, _ f: @escaping () -> Void) -> (() -> Void)? { on ? f : nil }

    private func crumbs() -> [CityCrumb] {
        var out = [CityCrumb(id: "city", title: "Ciudad", action: act(canStepOut) { goCity() })]
        let inside = inOffice || (frozenZoom.map { $0.p > 0 } ?? false)
        let c = inside ? (target.flatMap { model.campus(of: $0) } ?? campusFocus) : campusFocus
        if let c {
            out.append(CityCrumb(id: "campus", title: c, action: act(inside) { goCampus(c) }))
        }
        if inside, let pr = target {
            let atFloor = !(officeIsWorld && officeAll)
            out.append(CityCrumb(id: "project", title: pr, action: act(officeIsWorld && atFloor) { goBuilding() }))
            if atFloor, let plan = shownPlan {
                out.append(CityCrumb(id: "floor", title: plan.shortTitle, action: nil))
            }
        }
        if frozenZoom != nil { return out.map { CityCrumb(id: $0.id, title: $0.title, action: nil) } }
        return out
    }

    private func header(t: Double, chrome ch: Double) -> some View {
        let o = ch > 0 ? officeHeader(now: officeNow ?? Date()) : nil
        let back = frozenZoom == nil && canStepOut
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            CityBreadcrumb(crumbs: crumbs())
            Spacer()
            ZStack(alignment: .trailing) {
                Text("\(litCount(t)) de \(model.threadCount) hilos").opacity(CityTransition.chromeOut(ch))
                if let o { Text(o.count).opacity(CityTransition.chromeIn(ch)) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.trailing, 6)
            CityBackButton(enabled: back, shortcut: back && escapeZoomsOut, action: { stepOut() })
        }
    }

    // MARK: lienzo

    /// Lo que hay dentro del piso durante el zoom (el mismo contenido que se monta al llegar).
    private func zoomContent(now: Date) -> CityZoom.Content? {
        guard let pr = target else { return nil }
        let all = floors(pr)
        if let i = floorIndex(pr, floor: targetFloor, in: all) {
            let plan = all[i]
            return .floor(plan, box.layout(plan, frame: FloorFrame.building(all)), now: now)
        }
        return graph(pr).map { .graph(box.scene(graph: $0, tasks: tasks(pr))) }
    }

    static let storeyDesks = 2.9

    private func squash(_ b: CityBuilding, k: Double, amount u: Double) -> (CityModel, CityBuilding) {
        let goal = min(1, Self.storeyDesks * Iso.deskH * k / CityGeo.floorH)
        var nb = b
        nb.heightScale = 1 + (goal - 1) * u
        var m = model
        if let i = m.buildings.firstIndex(where: { $0.index == b.index }) { m.buildings[i] = nb }
        return (m, nb)
    }

    private func zoomData(p: Double, size: CGSize, content: CityZoom.Content?, city: IsoFrame) -> (CityZoom, IsoFrame, CityModel)? {
        guard p > 0, let pr = target, let fid = targetFloor, let content, let b0 = model.building(ofFloor: fid) ?? model.building(of: pr),
              let f = model.floor(id: fid) else { return nil }
        let emb: OfficeEmbedding, office: IsoFrame
        var m = model
        switch content {
        case .floor(_, let lay, _):
            let s = lay.shell
            guard s.w > 0, s.d > 0 else { return nil }
            let rooms = CGRect(x: s.x0, y: s.y0, width: s.w, height: s.d)
            let k = OfficeEmbedding(rooms: rooms, building: b0, level: f.level).k
            let u = cityClamp((p - 0.2) / 0.6)
            let (m2, b) = squash(b0, k: k, amount: u * u * (3 - 2 * u))
            let end = squash(b0, k: k, amount: 1).1
            m = m2
            emb = OfficeEmbedding(rooms: rooms, building: b, level: f.level)
            office = emb.officeFrame(fromCity: box.outFrame ?? CutawayFraming.frame(CutawayFraming.bounds(end, level: f.level), size: size))
        case .graph(let sc):
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for r in sc.rooms { minX = min(minX, r.x0); minY = min(minY, r.y0); maxX = max(maxX, r.x0 + r.w); maxY = max(maxY, r.y0 + r.d) }
            guard minX < maxX, minY < maxY else { return nil }  // piso sin salas: no hay a dónde acercarse
            emb = OfficeEmbedding(rooms: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), building: b0, level: f.level)
            office = OfficeFraming.frame(IsoBounds(minU: sc.minU, maxU: sc.maxU, minV: sc.minV, maxV: sc.maxV), size: size)
        }
        let tr = CityTransition(city: city, office: office, embedding: emb)
        return (CityZoom(project: pr, floorID: fid, p: p, transition: tr, content: content), tr.camera(p), m)
    }

    private struct Cut {
        let building: CityBuilding
        let floor: CityFloor
        let layout: FloorLayout
        let embedding: OfficeEmbedding
        let model: CityModel
    }

    private func cut(_ pr: String, plan: FloorPlan, all: [FloorPlan]) -> Cut? {
        guard let fid = cityFloorID(plan, project: pr), let b0 = model.building(ofFloor: fid), let f = model.floor(id: fid) else { return nil }
        let lay = box.layout(plan, frame: FloorFrame.building(all))
        let s = lay.shell
        guard s.w > 0, s.d > 0 else { return nil }
        let rooms = CGRect(x: s.x0, y: s.y0, width: s.w, height: s.d)
        let (m, b) = squash(b0, k: OfficeEmbedding(rooms: rooms, building: b0, level: f.level).k, amount: 1)
        return Cut(building: b, floor: f, layout: lay, embedding: OfficeEmbedding(rooms: rooms, building: b, level: f.level), model: m)
    }

    @ViewBuilder private func cutStage(_ pr: String, plan: FloorPlan) -> some View {
        let all = floors(pr)
        let items = pickerItems(all)
        if let c = cut(pr, plan: plan, all: all) {
            Group {
                if let ft = frozenTime { cutCanvas(pr, plan: plan, cut: c, t: ft, now: officeNow ?? Date()) }
                else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { cx in
                        cutCanvas(pr, plan: plan, cut: c, t: cx.date.timeIntervalSinceReferenceDate, now: officeNow ?? cx.date)
                    }
                }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.cut.frameInWindow = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let pt): box.cut.hovered = box.cut.dragging ? nil : box.cut.hit(pt)
                case .ended: box.cut.hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in box.cut.drag(to: v.translation) }
                .onEnded { _ in box.cut.endDrag() })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in box.cut.magnify(v.magnification, at: v.startLocation) }
                .onEnded { _ in box.cut.endMagnify() })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { _ in officeAll = false; box.cut.fitFloor() })
            .simultaneousGesture(SpatialTapGesture().onEnded { e in
                guard let id = box.cut.hit(e.location), let tid = Self.selection(ofSpot: id, in: plan) else { return }
                onInspect?(tid)
            })
            .onAppear { if frozenTime == nil { box.cut.install { stepFloor($0) } } }
            .onDisappear { box.cut.remove() }
            .overlay(alignment: .trailing) {
                if items.count > 1 { FloorPicker(items: items, current: Self.regionID(plan), onGo: { goFloor($0) }) }
            }
            .clipped()
        } else {
            OfficeWorldView(floors: all, frozenNow: officeNow, focusRegion: Self.regionID(plan), frame: FloorFrame.building(all),
                            onSelect: { tid in if let tid, FloorLayout.machinePart(tid) == nil { onInspect?(tid) } })
        }
    }

    private func cutCanvas(_ pr: String, plan: FloorPlan, cut c: Cut, t: Double, now: Date) -> some View {
        let dark = scheme == .dark
        let origin = frozenZoom != nil ? nil : zoomOrigin
        return Canvas { ctx, size in
            let level = c.floor.level
            let home = CutawayFraming.frame(CutawayFraming.bounds(c.building, level: level), size: size)
            let cam = box.cut.camera(key: c.floor.id, home: home, building: CutawayFraming.building(c.building, level: level), size: size,
                                     t: t, live: frozenTime == nil)
            let tr = CityTransition(city: cam, office: c.embedding.officeFrame(fromCity: home), embedding: c.embedding)
            var z = CityZoom(project: pr, floorID: c.floor.id, p: 1, transition: tr, content: .floor(plan, c.layout, now: now))
            z.floorBox = box.cut.floorBox
            z.hoveredSpot = box.cut.hovered
            CityRenderer(model: c.model, lights: lights, cam: cam, dark: dark, t: t, growth: growth, hovered: nil, zoom: z, size: size,
                         focusCampus: origin).draw(&ctx)
        } symbols: {
            FloorOfficeView.labels(plan, layout: c.layout, now: now, dark: dark)
        }
    }

    private func canvas(p: Double, t: Double) -> some View {
        let dark = scheme == .dark
        let floorNow = officeNow ?? Date()
        let inside = p > 0 ? zoomContent(now: floorNow) : nil
        let origin = frozenZoom != nil ? nil : zoomOrigin
        let goalCampus = frozenZoom != nil ? nil : campusFocus
        let animate = frozenTime == nil
        return Canvas { ctx, size in
            guard !model.buildings.isEmpty else { return }
            let z = zoomData(p: p, size: size, content: inside, city: levelFrame(size, campus: origin))
            let cam: IsoFrame
            if let z {
                cam = z.1
                box.ease.snap(cam)
            } else {
                cam = box.ease.frame(levelFrame(size, campus: goalCampus), t: t, animate: animate)
            }
            box.cityFrame = cam
            CityRenderer(model: z?.2 ?? model, lights: lights, cam: cam, dark: dark, t: t, growth: growth,
                         hovered: hovered, zoom: z?.0, size: size, focusCampus: z == nil ? goalCampus : origin).draw(&ctx)
        } symbols: {
            CitySymbols(model: model, lights: lights, t: t)
            // mismas etiquetas que la oficina que se monta al final (el piso acaba siendo esa vista)
            switch inside {
            case .floor(let plan, let lay, let now)?:
                FloorOfficeView.labels(plan, layout: lay, now: now, dark: dark)
            case .graph(let sc)?:
                ForEach(sc.desks) { d in
                    IsoDeskLabel(label: d.node.label, visual: d.visual).tag("d:\(d.id)")
                }
                ForEach(sc.rooms, id: \.index) { r in
                    IsoRoomLabel(index: r.index).tag("r:\(r.index)")
                }
            case nil:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                // solo con la ciudad quieta (p = 0): durante el zoom de vuelta el encuadre no es el de la ciudad
                let h = (zoomed || p > 0 || frozenTime != nil) ? nil : box.cityFrame.flatMap { CityHit.floorID(at: pt, in: model, frame: $0) }
                    .flatMap { id in model.floor(id: id).flatMap(project(of:)) == nil ? nil : id }
                if h != hovered { hovered = h }
            case .ended: hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { e in
            guard !zoomed, p == 0, let f = box.cityFrame else { return }
            if let id = CityHit.floorID(at: e.location, in: model, frame: f), let fl = model.floor(id: id) {
                guard let pr = project(of: fl) else { return }  // el vestíbulo compartido no entra
                select(pr, floor: fl.id)
            } else if frozenZoom == nil, let c = CityHit.campus(at: e.location, in: model, frame: f), c != campusFocus {
                campus = c
            }
        })
        .simultaneousGesture(MagnifyGesture().onEnded { v in
            guard frozenZoom == nil, frozenTime == nil, !zoomed, p == 0 else { return }
            if v.magnification < 0.85 {
                if campusFocus != nil { campus = nil }
            } else if v.magnification > 1.18, campusFocus == nil, let f = box.cityFrame,
                      let c = CityHit.campus(at: v.startLocation, in: model, frame: f) {
                campus = c
            }
        })
    }

    private func overlay(p: Double, chrome ch: Double) -> some View {
        // un aviso por piso (id = `CityFloor.id`); el del vestíbulo lleva el proyecto del hilo y su clic entra en esa oficina
        let cityAlerts = model.alerts.map { a in
            let fl = model.floor(id: a.floor)
            let label = fl.map { $0.isLobby ? "Vestíbulo · \(a.project)" : $0.label } ?? a.project
            return IsoAlert(id: a.floor.isEmpty ? a.project : a.floor, label: label, title: a.title,
                            visual: a.status == .needsYou ? .needsYou : .stuck)
        }
        // dentro de una oficina no hay barra encima (visualizador puro); solo en la vista Grafo del proyecto sin pisos
        let officeAlerts: [IsoAlert] = targetPlan != nil ? [] :
            target.flatMap { pr in graph(pr).map { Self.officeAlerts(box.scene(graph: $0, tasks: tasks(pr)), tasks: tasks(pr)) } } ?? []
        return ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .top) {
                if !cityAlerts.isEmpty && ch < 1 {
                    IsoAttentionBar(items: cityAlerts, selected: nil, flat: flatChrome) { id in
                        select(model.alerts.first { $0.floor == id }?.project ?? id,
                               floor: model.floor(id: id).flatMap { $0.isLobby ? nil : $0.id })
                    }
                        .padding(.top, 12).opacity(CityTransition.chromeOut(ch)).allowsHitTesting(p == 0)
                }
                // la barra que tendrá la oficina, en el mismo sitio (al montarse la vista del piso no cambia nada)
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

struct CityCrumb: Identifiable {
    let id: String
    let title: String
    let action: (() -> Void)?
}

@available(macOS 26.0, *)
struct CityBreadcrumb: View {
    let crumbs: [CityCrumb]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, c in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
                if let a = c.action {
                    Button(action: a) { Text(c.title).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.secondary)
                } else {
                    Text(c.title).foregroundStyle(i == crumbs.count - 1 ? Color.primary : Color.secondary)
                }
            }
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
    }
}

@available(macOS 26.0, *)
struct CityBackButton: View {
    let enabled: Bool
    let shortcut: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("← Volver")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(enabled ? 0.12 : 0.05)))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(shortcut ? KeyboardShortcut.cancelAction : nil)
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

@available(macOS 26.0, *)
struct CityCampusTag: View {
    let name: String
    let projects: Int
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("\(name.uppercased())  ·  \(projects) \(projects == 1 ? "proyecto" : "proyectos")")
            .font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(scheme == .dark ? Color(white: 0.05).opacity(0.85) : Color.white.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.28), lineWidth: 0.8))
            .foregroundStyle(Color.primary.opacity(0.8))
    }
}

@available(macOS 26.0, *)
struct CitySymbols: View {
    let model: CityModel
    let lights: CityLights
    let t: Double

    var body: some View {
        ForEach(model.floors) { f in
            CityFloorPill(name: f.label, tint: lights.tint(f.id, t: t)).tag("cf:\(f.id)")
        }
        ForEach(model.buildings, id: \.index) { b in
            CityCompanyTag(name: b.displayName, threads: b.floors.reduce(0) { $0 + $1.activeThreads.count }).tag("cb:\(b.company)")
        }
        ForEach(model.campuses) { c in
            CityCampusTag(name: c.name, projects: model.buildings.filter { $0.campus == c.name }.count).tag("cc:\(c.name)")
        }
    }
}

@available(macOS 26.0, *)
final class CityCameraEase {
    private(set) var current: IsoFrame?
    private var lastT = 0.0

    func frame(_ goal: IsoFrame, t: Double, animate: Bool = true) -> IsoFrame {
        guard animate, var c = current else { current = goal; lastT = t; return goal }
        if t < lastT - 0.5 { lastT = t }
        let dt = min(0.1, max(0, t - lastT)); lastT = t
        let k = 1 - exp(-dt * 6)
        c.s = exp(log(c.s) + (log(goal.s) - log(c.s)) * k)
        c.cu += (goal.cu - c.cu) * k; c.cv += (goal.cv - c.cv) * k
        c.ax += (goal.ax - c.ax) * k; c.ay += (goal.ay - c.ay) * k
        if abs(log(c.s / goal.s)) < 1e-3, abs(c.cu - goal.cu) * c.s < 0.3, abs(c.cv - goal.cv) * c.s < 0.3,
           abs(c.ax - goal.ax) < 0.3, abs(c.ay - goal.ay) < 0.3 { c = goal }
        current = c
        return c
    }

    func snap(_ f: IsoFrame) { current = f }
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
    let index: Int
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text("RANGO \(index + 1)")
            .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(scheme == .dark ? Color(white: 0.11).opacity(0.92) : Color.white.opacity(0.9)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.7))
            .foregroundStyle(Color.primary.opacity(0.75))
    }
}

// MARK: - En vivo

/// Ciudad en vivo (macOS 26): la flota del `LiveStore` (el mismo estado que pinta la oficina). `onSelectFloor` recibe el proyecto
/// del piso pulsado (la vista ya hace el zoom a su oficina). La app la abre desde la barra lateral («Ciudad»); el banco de pruebas,
/// desde la escena "Ciudad".
@available(macOS 26.0, *)
public struct LiveCityScreen: View {
    #if DEBUG && HOT_RELOAD
    @ObserveInjection var inject
    #endif
    @ObservedObject var store: LiveStore
    let directory: CompanyDirectory
    let onSelectFloor: ((String) -> Void)?
    /// Un edificio por proyecto (la barra lateral de la app) o uno por empresa (banco de pruebas).
    let perProject: Bool
    @State private var model = CityModel(buildings: [], groundX: 1, groundY: 1)
    @State private var lights = CityLights()

    public init(store: LiveStore, directory: CompanyDirectory = .standard, perProject: Bool = false, onSelectFloor: ((String) -> Void)? = nil) {
        self.store = store; self.directory = directory; self.perProject = perProject; self.onSelectFloor = onSelectFloor
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
                CityView(model: model, lights: lights, snapshot: store.snapshot, state: store.state, onSelectFloor: onSelectFloor)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Ciudad")
        .navigationSubtitle(perProject ? "\(model.projectCount) proyectos" : "\(model.campuses.count) empresas · \(model.projectCount) proyectos")
        .toolbar { ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: store.snapshot.machines) } }
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
        .hotReload()
    }

    private func refresh() {
        let m = CityModel.build(store.state, directory: directory, perProject: perProject)
        lights.observe(m, at: Date().timeIntervalSinceReferenceDate)
        if m != model { model = m }
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
