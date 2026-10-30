import SwiftUI

@available(macOS 26.0, *)
public struct CityFocus: Equatable, Sendable {
    public var project: String
    public var p: Double
    public var floor: String?
    public init(project: String, p: Double, floor: String? = nil) { self.project = project; self.p = p; self.floor = floor }
}

@available(macOS 26.0, *)
final class CityViewBox {
    var cityFrame: IsoFrame?
    var sceneKey: LiveSceneKey?
    var cachedScene: IsoScene?
    var zoomGen = 0

    func scene(graph: MockGraph, tasks: [String: MockTask]) -> IsoScene {
        let k = LiveSceneKey(graph: graph, tasks: tasks)
        if let s = cachedScene, sceneKey == k { return s }
        let s = IsoScene(graph: graph, tasks: tasks)
        cachedScene = s; sceneKey = k
        return s
    }
}

@available(macOS 26.0, *)
public struct CityView: View {
    let model: CityModel
    let lights: CityLights
    let snapshot: MockSnapshot
    let state: LiveState?
    var frozenTime: Double?
    var frozenNow: Date?
    var growth: Double?
    var frozenZoom: CityFocus?
    var flatChrome: Bool
    var onSelectFloor: ((String) -> Void)?
    var onInspect: ((String) -> Void)?
    var focusRequest: ShellFocus?
    var escapeZoomsOut = true

    @State private var box = CityViewBox()
    @State private var focus: String?
    @State private var focusFloor: String?
    @State private var zoomFrom = 0.0
    @State private var zoomTo = 0.0
    @State private var zoomAt = -Double.infinity
    @State private var mounted = false
    @State private var hovered: String?
    @Environment(\.colorScheme) private var scheme

    public static let zoomDuration = 2.4

    public init(state: LiveState, lights: CityLights, directory: CompanyDirectory = .standard, onSelectFloor: ((String) -> Void)? = nil,
                onInspect: ((String) -> Void)? = nil, focusRequest: ShellFocus? = nil, escapeZoomsOut: Bool = true) {
        self.init(model: CityModel.build(state, directory: directory), lights: lights, snapshot: SnapshotMapper.snapshot(state),
                  state: state, onSelectFloor: onSelectFloor, onInspect: onInspect, focusRequest: focusRequest, escapeZoomsOut: escapeZoomsOut)
    }

    init(model: CityModel, lights: CityLights, snapshot: MockSnapshot, state: LiveState? = nil, frozenTime: Double? = nil,
         frozenNow: Date? = nil, growth: Double? = nil, frozenZoom: CityFocus? = nil, flatChrome: Bool = false,
         onSelectFloor: ((String) -> Void)? = nil, onInspect: ((String) -> Void)? = nil, focusRequest: ShellFocus? = nil,
         escapeZoomsOut: Bool = true) {
        self.model = model; self.lights = lights; self.snapshot = snapshot; self.state = state; self.frozenTime = frozenTime
        self.frozenNow = frozenNow; self.growth = growth; self.frozenZoom = frozenZoom; self.flatChrome = flatChrome
        self.onSelectFloor = onSelectFloor; self.onInspect = onInspect; self.focusRequest = focusRequest
        self.escapeZoomsOut = escapeZoomsOut
    }

    private var target: String? { frozenZoom?.project ?? focus }

    private var targetFloor: String? {
        guard let pr = target else { return nil }
        let chosen = frozenZoom != nil ? frozenZoom?.floor : focusFloor
        return chosen ?? model.floor(pr)?.id
    }

    private var targetPlan: FloorPlan? { target.flatMap { plan($0, floor: targetFloor) } }

    private func floors(_ project: String) -> [FloorPlan] {
        state.map { ProjectOffice.floors(in: $0, project: project, now: officeNow ?? Date()) } ?? []
    }

    private func floorIndex(_ project: String, floor id: String?, in all: [FloorPlan]) -> Int? {
        guard !all.isEmpty else { return nil }
        let idx = id.flatMap { model.floor(id: $0) }.flatMap { $0.isLobby ? nil : $0.floorIndex }
        return idx.flatMap { i in all.firstIndex { $0.kind != .lobby && $0.floorIndex == i } }
            ?? all.firstIndex { $0.kind != .lobby } ?? 0
    }

    private func project(of fl: CityFloor) -> String? {
        guard fl.isLobby else { return fl.project }
        let ps = Set(model.buildings.first { $0.floors.contains { $0.id == fl.id } }?.floors.filter { !$0.isLobby }.map(\.project) ?? [])
        return ps.count == 1 ? ps.first : nil
    }

    private func plan(_ project: String, floor id: String?) -> FloorPlan? {
        let all = floors(project)
        return floorIndex(project, floor: id, in: all).map { all[$0] }
    }

    private func canZoom(_ project: String) -> Bool { plan(project, floor: nil) != nil || graph(project) != nil }

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

    private func select(_ project: String, floor: String? = nil, notify: Bool = true) {
        if notify { onSelectFloor?(project) }
        guard frozenZoom == nil, canZoom(project) else { return }
        zoomIn(project, floor: floor)
    }

    private func zoomIn(_ project: String, floor: String?) {
        let t = now()
        let cur = focus == project && focusFloor == floor ? progress(t) : 0
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
        mounted = false
        zoomFrom = cur; zoomTo = 0; zoomAt = t
        box.zoomGen += 1
        let gen = box.zoomGen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.zoomDuration * cur * 1_000_000_000))
            if box.zoomGen == gen { focus = nil; focusFloor = nil }
        }
    }

    private var zoomed: Bool { frozenZoom.map { $0.p > 0 } ?? (focus != nil && zoomTo > 0) }

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
        .onChange(of: focusRequest) { _, r in
            guard let r else { return }
            if let pr = r.target.project {
                if pr != focus || !(zoomed || mounted) { select(pr, notify: false) }
            } else if zoomed || mounted {
                zoomOut()
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
                if office, let pr = target, let state, let plan = targetPlan {
                    OfficeWorldView(state: state, project: pr, now: officeNow,
                                    focusRegion: plan.kind == .lobby ? "lobby:\(plan.name ?? "")" : "floor:\(plan.floorIndex)",
                                    onSelect: { tid in if let tid, FloorLayout.machinePart(tid) == nil { onInspect?(tid) } })
                } else if office, let pr = target, let g = graph(pr) {
                    IsoOfficeView(graph: g, tasks: tasks(pr), hostOf: hosts(pr), frozenTime: frozenTime, flatChrome: flatChrome)
                } else {
                    canvas(p: p, t: t)
                    overlay(p: p, chrome: ch)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(IsoBackdrop())
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func litCount(_ t: Double) -> Int {
        model.floors.reduce(0) { $0 + lights.windows($1.id, t: t).filter { $0 > 0.5 }.count }
    }

    private func officeHeader(now: Date) -> (title: String, count: String)? {
        guard let pr = target else { return nil }
        if let plan = targetPlan {
            let desks = plan.desks.filter { !$0.retired }
            let busy = desks.filter { plan.occupant(of: $0.id, now: now) != nil }.count
            return (plan.name.map { "\(pr) · \($0)" } ?? pr, "\(busy) de \(desks.count) escritorios")
        }
        return graph(pr).map { ($0.goal, "\($0.threads) de \($0.threadBudget) hilos") }
    }

    private func header(t: Double, chrome ch: Double) -> some View {
        let o = ch > 0 ? officeHeader(now: officeNow ?? Date()) : nil
        return HStack(alignment: .firstTextBaseline) {
            ZStack(alignment: .leading) {
                Text("Todas las empresas").opacity(CityTransition.chromeOut(ch))
                if let o { Text(o.title).opacity(CityTransition.chromeIn(ch)) }
            }
            .font(.callout.weight(.medium))
            Spacer()
            ZStack(alignment: .trailing) {
                Text("\(litCount(t)) de \(model.threadCount) hilos").opacity(CityTransition.chromeOut(ch))
                if let o { Text(o.count).opacity(CityTransition.chromeIn(ch)) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.trailing, 6)
            CitySwitch(first: ch > 0.5 ? "Oficina" : "Ciudad", zoomed: (zoomed || mounted) && escapeZoomsOut,
                       pickFirst: { if zoomed || mounted { zoomOut() } })
        }
    }

    private func zoomContent(now: Date) -> CityZoom.Content? {
        guard let pr = target else { return nil }
        if let plan = targetPlan { return .floor(plan, FloorLayout(plan: plan), now: now) }
        return graph(pr).map { .graph(box.scene(graph: $0, tasks: tasks(pr))) }
    }

    private func zoomData(p: Double, size: CGSize, content: CityZoom.Content?) -> (CityZoom, IsoFrame)? {
        guard p > 0, let pr = target, let fid = targetFloor, let content, let b = model.building(of: pr),
              let f = model.floor(id: fid) else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        let bounds: IsoBounds
        switch content {
        case .floor(_, let lay, _):
            for r in lay.rooms { minX = min(minX, r.x0); minY = min(minY, r.y0); maxX = max(maxX, r.x0 + r.w); maxY = max(maxY, r.y0 + r.d) }
            bounds = IsoBounds(minU: lay.minU, maxU: lay.maxU, minV: lay.minV, maxV: lay.maxV)
        case .graph(let sc):
            for r in sc.rooms { minX = min(minX, r.x0); minY = min(minY, r.y0); maxX = max(maxX, r.x0 + r.w); maxY = max(maxY, r.y0 + r.d) }
            bounds = IsoBounds(minU: sc.minU, maxU: sc.maxU, minV: sc.minV, maxV: sc.maxV)
        }
        guard minX < maxX, minY < maxY else { return nil }
        let emb = OfficeEmbedding(rooms: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), building: b, level: f.level)
        let office = OfficeFraming.frame(bounds, size: size)
        let tr = CityTransition(city: CityFraming.frame(model.bounds, size: size), office: office, embedding: emb)
        return (CityZoom(project: pr, floorID: fid, p: p, transition: tr, content: content), tr.camera(p))
    }

    private func canvas(p: Double, t: Double) -> some View {
        let dark = scheme == .dark
        let floorNow = officeNow ?? Date()
        let inside = p > 0 ? zoomContent(now: floorNow) : nil
        return Canvas { ctx, size in
            guard !model.buildings.isEmpty else { return }
            let cityF = CityFraming.frame(model.bounds, size: size)
            box.cityFrame = cityF
            let z = zoomData(p: p, size: size, content: inside)
            CityRenderer(model: model, lights: lights, cam: z?.1 ?? cityF, dark: dark, t: t, growth: growth,
                         hovered: hovered, zoom: z?.0, size: size).draw(&ctx)
        } symbols: {
            ForEach(model.floors) { f in
                CityFloorPill(name: f.label, tint: lights.tint(f.id, t: t)).tag("cf:\(f.id)")
            }
            ForEach(model.buildings, id: \.index) { b in
                CityCompanyTag(name: b.company, threads: b.floors.reduce(0) { $0 + $1.activeThreads.count }).tag("cb:\(b.company)")
            }
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
                let h = (zoomed || p > 0 || frozenTime != nil) ? nil : box.cityFrame.flatMap { CityHit.floorID(at: pt, in: model, frame: $0) }
                if h != hovered { hovered = h }
            case .ended: hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { e in
            guard !zoomed, p == 0, let f = box.cityFrame, let id = CityHit.floorID(at: e.location, in: model, frame: f),
                  let fl = model.floor(id: id), let pr = project(of: fl) else { return }
            select(pr, floor: fl.isLobby ? nil : fl.id)
        })
    }

    private func overlay(p: Double, chrome ch: Double) -> some View {
        let cityAlerts = model.alerts.map { a in
            let fl = model.floor(id: a.floor)
            let label = fl.map { $0.isLobby ? "Vestíbulo · \(a.project)" : $0.label } ?? a.project
            return IsoAlert(id: a.floor.isEmpty ? a.project : a.floor, label: label, title: a.title,
                            visual: a.status == .needsYou ? .needsYou : .stuck)
        }
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

    static func officeAlerts(_ sc: IsoScene, tasks: [String: MockTask]) -> [IsoAlert] {
        sc.desks.filter { $0.visual == .needsYou || $0.visual == .stuck }
            .sorted { ($0.visual == .needsYou ? 0 : 1, $0.id) < ($1.visual == .needsYou ? 0 : 1, $1.id) }
            .map { IsoAlert(id: $0.id, label: $0.node.label, title: $0.node.task.flatMap { tasks[$0]?.title } ?? $0.node.title, visual: $0.visual) }
    }
}

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

@available(macOS 26.0, *)
struct CitySwitch: View {
    let first: String
    let zoomed: Bool
    let pickFirst: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            segment(first, on: true, action: pickFirst)
                .keyboardShortcut(zoomed ? KeyboardShortcut(.escape, modifiers: []) : nil)
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

@available(macOS 26.0, *)
public struct LiveCityScreen: View {
    @ObservedObject var store: LiveStore
    let directory: CompanyDirectory
    let onSelectFloor: ((String) -> Void)?
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
        .navigationSubtitle(perProject ? "\(model.projectCount) proyectos" : "\(model.buildings.count) empresas · \(model.projectCount) proyectos")
        .toolbar { ToolbarItem(placement: .primaryAction) { MachineStatusButton(machines: store.snapshot.machines) } }
        .onAppear { refresh() }
        .onReceive(store.$snapshot) { _ in refresh() }
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
