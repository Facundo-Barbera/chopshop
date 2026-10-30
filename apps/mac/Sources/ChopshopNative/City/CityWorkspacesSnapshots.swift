import SwiftUI
import AppKit

@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    static func renderCityWorkspaces(to out: String) {
        guard let state = CityOfficeFixture.state,
              let cloud = try? JSONDecoder().decode(BackendState.self, from: Data(CityWorkspacesDemo.state.utf8)) else {
            print("sin datos de la ciudad"); return
        }
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        let owner = CityWorkspacesDemo.model(canEdit: true)
        let watcher = CityWorkspacesDemo.model(canEdit: false)
        let store = LiveStore()
        let model = CityModel.build(state, cloud: cloud, perProject: true, seed: 11)
        var lights = CityLights()
        lights.observe(model, at: 0)
        let snap = SnapshotMapper.snapshot(state, now: FloorFixture.now)
        let city = ZStack(alignment: .bottomLeading) {
            CityView(model: model, lights: lights, snapshot: snap, state: state, frozenTime: 10, frozenNow: FloorFixture.now, flatChrome: true)
                .padding(.horizontal, 18).padding(.vertical, 14)
            CityWorkspacesBar(model: owner, store: store).padding(.leading, 30).padding(.bottom, 48)
        }
        .frame(width: 1280, height: 800)
        let project = owner.projects(in: "w-awe").first
        let shots: [(String, AnyView)] = [
            ("ciudad", AnyView(city)),
            ("editor", AnyView(CityWorkspacesEditorPreview(model: owner, selection: "w-awe"))),
            ("editor-watcher", AnyView(CityWorkspacesEditorPreview(model: watcher, selection: "w-per"))),
            ("proyecto", AnyView(CityProjectEditor(model: owner, edit: CityProjectEdit(workspaceID: "w-awe", project: project)))),
            ("proyecto-nuevo", AnyView(CityProjectEditor(model: owner, edit: CityProjectEdit(workspaceID: "w-per", project: nil)))),
            ("pisos", AnyView(project.map { AnyView(CityProjectLayoutEditor(model: owner, project: $0)) } ?? AnyView(EmptyView()))),
            ("importar", AnyView(CityImportSheet(model: owner))),
        ]
        for (name, view) in shots {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = "\(out)/city-workspaces-\(name).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("ok \(path)")
        }
    }
}

@available(macOS 26.0, *)
private struct CityWorkspacesEditorPreview: View {
    @ObservedObject var model: CityWorkspacesModel
    let selection: String

    var body: some View {
        HStack(spacing: 0) {
            List(model.ordered, id: \.id) { w in
                Text(w.name).fontWeight(w.id == selection ? .semibold : .regular)
            }
            .frame(width: 240)
            Divider()
            CityWorkspaceDetail(model: model, workspaceID: selection)
        }
        .frame(width: 900, height: 620)
    }
}

@MainActor
enum CityWorkspacesDemo {
    static func model(canEdit: Bool) -> CityWorkspacesModel {
        let api = URL(string: "https://api.example.test")!
        let store = InMemorySessionStore()
        try? store.save("ss1_" + String(repeating: "x", count: 43), apiURL: api)
        let client = BackendClient(apiURL: api, session: store, transport: CannedTransport(responses: responses), deviceName: "mac-mini")
        let m = CityWorkspacesModel(client: client, canEdit: canEdit)
        Task { await m.reload() }
        let until = Date().addingTimeInterval(2)
        while !m.loaded && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return m
    }

    static func workspace(_ id: String, _ name: String, _ position: Int, style: String) -> String {
        #"{"id":"\#(id)","name":"\#(name)","slug":"\#(id)","position":\#(position),"style":\#(style),"rev":2,"project_count":2,"machine_ids":["m1"],"watcher_count":1}"#
    }

    static func project(_ id: String, _ name: String, _ ws: String, title: String? = nil, machine: String? = "m1") -> String {
        let t = title.map { "\"\($0)\"" } ?? "null", m = machine.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","workspace_id":"\#(ws)","name":"\#(name)","title":\#(t),"t3_project":"\#(name)","repo":null,"machine_id":\#(m),"runtime_mode":"approval-required","model":null,"settings":{},"position":0,"rev":3,"created_at":"t","updated_at":"t","disabled_at":null,"archived_at":null}"#
    }

    static let layout = #"{"layout":{"floors":[{"name":"Producto","rooms":[{"role":"triage","desks":1,"permanent":true},{"role":"backend","desks":4},{"role":"frontend","desks":3}]},{"name":"Docs y entrega","rooms":[{"role":"docs","desks":1,"permanent":true},{"role":"qa","desks":1}]}],"half_life":"10m"},"rev":4}"#

    static let responses: [String: String] = [
        "GET /v1/workspaces": #"{"workspaces":[\#(workspace("w-awe", "Awesome GB", 0, style: ##"{"material":"brick","color":"#3a7bd5"}"##)),\#(workspace("w-per", "Personal", 1, style: "{}"))]}"#,
        "GET /v1/workspaces/w-awe/projects": #"{"projects":[\#(project("p1", "awesome-gb", "w-awe", title: "Awesome GB")),\#(project("p2", "awesome-docs", "w-awe", machine: nil))]}"#,
        "GET /v1/workspaces/w-per/projects": #"{"projects":[\#(project("p3", "chopshop", "w-per")),\#(project("p4", "life", "w-per"))]}"#,
        "GET /v1/workspaces/w-awe/campus": #"{"layout":{"buildings":[{"project":"awesome-gb","x":0,"y":0},{"project":"awesome-docs","x":1,"y":0}]},"rev":3}"#,
        "GET /v1/workspaces/w-per/campus": #"{"layout":{},"rev":1}"#,
        "GET /v1/projects/p1/layout": layout,
        "GET /v1/machines": #"{"machines":[{"id":"m1","name":"mac-mini","platform":"macos","local_machine_id":null,"linked_via":"app","agent_version":"2.0.0","workspace_ids":["w-awe","w-per"],"created_at":"t","last_seen_at":"t","paused_at":null,"revoked_at":null,"online":true}]}"#,
        "GET /v1/imports": #"{"imports":[{"id":"i1","machine_id":"m1","created_at":"2026-10-30T12:00:00.000Z","summary":[],"applied_at":null,"dismissed_at":null}]}"#,
        "GET /v1/imports/i1": #"{"import":{"id":"i1","machine_id":"m1","created_at":"2026-10-30T12:00:00.000Z","summary":[],"applied_at":null,"dismissed_at":null},"projects":[{"name":"nuskills","company":"iAware","t3_project":"nuskills","repo":null,"roles":["triage","backend"],"floors":2,"has_prompts":true,"conflicts":[]},{"name":"ozom-gv","company":"Awesome GB","t3_project":null,"repo":null,"roles":[],"floors":0,"has_prompts":false,"conflicts":[]},{"name":"chopshop","company":"Personal","t3_project":null,"repo":null,"roles":[],"floors":0,"has_prompts":false,"conflicts":["name_taken"]}]}"#,
    ]

    static let state = #"""
    {"v":2,"type":"state","id":"x","ts":"t","rev":7,"head":"e-1","user":{"id":"u1","role":"owner"},
     "city":{"workspaces":[
      {"id":"w-awe","name":"Awesome GB","slug":"awesome-gb","position":0,"style":{"material":"brick"},"campus":{"layout":{"buildings":[{"project":"awesome-gb","x":0,"y":0},{"project":"awesome-docs","x":1,"y":0}]},"rev":3},
       "projects":[{"id":"p1","name":"awesome-gb","title":null,"machine_id":"m1","disabled":false,"layout":{},"roles":[],"sync_errors":[]},
                   {"id":"p2","name":"awesome-docs","title":null,"machine_id":null,"disabled":false,"layout":{},"roles":[],"sync_errors":[]}],"machine_ids":["m1"]},
      {"id":"w-per","name":"Personal","slug":"personal","position":1,"style":{},"campus":{"layout":{},"rev":1},
       "projects":[{"id":"p3","name":"chopshop","title":null,"machine_id":"m1","disabled":false,"layout":{},"roles":[],"sync_errors":[]},
                   {"id":"p4","name":"life","title":null,"machine_id":"m1","disabled":false,"layout":{},"roles":[],"sync_errors":[]}],"machine_ids":["m1"]}]},
     "machines":[],"snapshots":[]}
    """#
}

private struct CannedTransport: HTTPTransport {
    let responses: [String: String]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let body = responses[key]
        let resp = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        return (Data((body ?? #"{"v":2,"type":"error","code":"not_found","message":"no existe"}"#).utf8), resp)
    }
}
