import XCTest
@testable import ChopshopNative

/// Armazón de la oficina (docs/plans/office-first-ui.md): HUD, paneles, Esc, ciclo de atención, paleta y minimapa. Todo puro.
final class ShellModelTests: XCTestCase {
    let snap = Fixtures.snapshot

    // MARK: HUD

    func testHUDCountsAttentionRunningAndMachines() {
        let h = ShellHUD.from(snap)
        let all = snap.projects.map(snap.summary(of:))
        XCTAssertEqual(h.needsYou, all.map(\.needsYou).reduce(0, +))
        XCTAssertEqual(h.stuck, all.map(\.stuck).reduce(0, +))
        XCTAssertEqual(h.running, all.map(\.running).reduce(0, +))
        XCTAssertEqual(h.machinesTotal, snap.machines.count)
        XCTAssertGreaterThan(h.attention, 0, "el fixture tiene preguntas y tareas trabadas")
        XCTAssertTrue(h.attentionLabel.hasSuffix("te necesitan"))
    }

    func testHUDLabelsWhenCalm() {
        let h = ShellHUD()
        XCTAssertEqual(h.attentionLabel, "nada pendiente")
        XCTAssertEqual(h.machinesLabel, "sin máquinas")
        XCTAssertFalse(h.machinesAlert)
        XCTAssertEqual(ShellHUD(needsYou: 1).attentionLabel, "1 te necesita")
        XCTAssertTrue(ShellHUD(machinesOK: 2, machinesTotal: 3).machinesAlert, "una máquina caída pide atención")
        XCTAssertTrue(ShellHUD(machinesOK: 3, machinesTotal: 3, machinesHot: 1).machinesAlert, "una saturada también")
    }

    // MARK: paneles y Esc

    func testTogglePanelAndInspector() {
        var s = ShellState()
        XCTAssertNil(s.inspector)
        s.toggle(.activity)
        XCTAssertEqual(s.inspector, .panel(.activity))
        s.toggle(.activity)
        XCTAssertNil(s.inspector, "el mismo atajo lo cierra")
        s.toggleInspector()
        XCTAssertEqual(s.inspector, .panel(.activity), "⌘\\ vuelve a abrir lo último")
        s.toggle(.batches)
        XCTAssertEqual(s.inspector, .panel(.batches), "otro panel lo sustituye")
    }

    func testEscapeClosesPaletteThenPanelThenLetsTheWorldHaveIt() {
        var s = ShellState()
        s.toggle(.attention)
        s.openPalette()
        s.query = "resp"
        XCTAssertTrue(s.escape())
        XCTAssertFalse(s.paletteOpen)
        XCTAssertEqual(s.query, "", "cerrar la paleta borra la búsqueda")
        XCTAssertEqual(s.inspector, .panel(.attention), "el primer Esc solo cierra la paleta")
        XCTAssertTrue(s.escape())
        XCTAssertNil(s.inspector)
        XCTAssertFalse(s.escape(), "sin nada abierto el Esc es del mundo (salir del piso)")
    }

    func testSelectFromWorldOpensDetailWithoutMovingTheCamera() {
        var s = ShellState()
        s.select(.thread(id: "t-0056", project: "nuskills"))
        XCTAssertEqual(s.inspector, .target(.thread(id: "t-0056", project: "nuskills")))
        XCTAssertEqual(s.selectedThread, "t-0056")
        XCTAssertNil(s.focus, "lo eligió el mundo: ya está ahí")
        s.select(.project("chopshop"))
        XCTAssertNil(s.selectedThread)
        XCTAssertEqual(s.inspector, .target(.project("chopshop")))
    }

    func testGoAsksTheWorldWithANewTokenEachTime() {
        var s = ShellState()
        s.go(.project("nuskills"))
        let a = s.focus
        s.go(.project("nuskills"))
        XCTAssertEqual(a?.target, .project("nuskills"))
        XCTAssertEqual(s.focus?.token, (a?.token ?? 0) + 1, "pedir lo mismo otra vez vuelve a hacer zoom")
        s.go(.city)
        XCTAssertEqual(s.focus?.target, .city)
        XCTAssertEqual(s.inspector, .target(.project("nuskills")), "volver a la ciudad no cierra el panel")
    }

    // MARK: atención

    func testAttentionItemsPutDecisionsBeforeStuck() {
        let items = ShellAttention.items(snap)
        XCTAssertFalse(items.isEmpty)
        let states = items.map(\.state)
        XCTAssertEqual(states, states.sorted(), "primero te necesita, luego trabadas")
        XCTAssertTrue(states.allSatisfy { $0 == .needsYou || $0 == .stuck })
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "sin repetidos")
    }

    func testCycleAttentionWrapsBothWays() {
        let items = ShellAttention.items(snap)
        var s = ShellState()
        let first = s.cycleAttention(items)
        XCTAssertEqual(first?.threadID, items.first?.threadID)
        XCTAssertEqual(s.focus?.target, .thread(id: items[0].threadID, project: items[0].project), "va al escritorio")
        XCTAssertEqual(s.inspector, .target(.thread(id: items[0].threadID, project: items[0].project)))
        let prev = s.cycleAttention(items, forward: false)
        XCTAssertEqual(prev?.threadID, items.last?.threadID, "hacia atrás desde el primero da la vuelta")
        _ = s.cycleAttention(items)
        XCTAssertEqual(s.selectedThread, items.first?.threadID)
        var empty = ShellState()
        XCTAssertNil(empty.cycleAttention([]))
    }

    func testCycleAttentionFollowsTheSelectedThread() {
        let items = ShellAttention.items(snap)
        guard items.count >= 3 else { return XCTFail("el fixture necesita al menos 3 pendientes") }
        var s = ShellState()
        s.select(.thread(id: items[1].threadID, project: items[1].project))
        XCTAssertEqual(s.cycleAttention(items)?.threadID, items[2].threadID, "sigue desde lo que elegiste en el mundo")
    }

    // MARK: paleta

    func testCommandsCoverAnswerSettleGoPanelsAndCLIOnly() {
        let cmds = ShellCommands.all(snap)
        let kinds = cmds.map(\.kind)
        XCTAssertTrue(kinds.contains { if case .answer(let id, _, "Bloquear") = $0 { return id == "t-0056" }; return false })
        XCTAssertTrue(kinds.contains { if case .settle("t-0042", "bixku-utilities") = $0 { return true }; return false }, "terminada → settle")
        XCTAssertFalse(kinds.contains { if case .settle("t-0041", _) = $0 { return true }; return false }, "corriendo: no se cierra")
        XCTAssertTrue(kinds.contains(.go(.project("nuskills"))))
        XCTAssertTrue(kinds.contains(.go(.city)))
        for p in ShellPanel.allCases { XCTAssertTrue(kinds.contains(.panel(p)), "panel \(p)") }
        XCTAssertTrue(kinds.contains { if case .cliOnly(let c) = $0 { return c.hasPrefix("chopshop fanout nuskills") }; return false })
        XCTAssertTrue(kinds.contains { if case .cliOnly(let c) = $0 { return c.hasPrefix("chopshop graph run") }; return false })
        XCTAssertEqual(Set(cmds.map(\.id)).count, cmds.count, "ids únicos (la lista de SwiftUI los usa)")
        XCTAssertEqual(cmds.first?.kind, .nextAttention, "sin búsqueda, lo primero es lo que te necesita")
    }

    func testSelectedThreadGoesFirst() {
        let cmds = ShellCommands.all(snap, selected: "t-0042")
        let firstSettle = cmds.first { if case .settle = $0.kind { return true }; return false }
        XCTAssertEqual(firstSettle?.id, "settle:t-0042")
    }

    func testFuzzySearchIgnoresCaseAndAccentsAndRanksWordStarts() {
        let cmds = ShellCommands.all(snap)
        let r = ShellCommands.search("bloquear", in: cmds)
        XCTAssertEqual(r.first?.kind, .answer(threadID: "t-0056", project: "nuskills", option: "Bloquear"))
        XCTAssertFalse(ShellCommands.search("ACTIVIDAD", in: cmds).isEmpty, "sin mayúsculas")
        XCTAssertEqual(ShellCommands.search("sala maquinas", in: cmds).first?.kind, .panel(.machineRoom), "sin tildes")
        XCTAssertTrue(ShellCommands.search("zzzqqq", in: cmds).isEmpty)
        XCTAssertEqual(ShellCommands.search("", in: cmds, limit: 5).map(\.id), cmds.prefix(5).map(\.id), "vacío = orden de all")
    }

    func testScoreIsSubsequence() {
        XCTAssertNotNil(ShellCommands.score("pnl", in: "panel lotes"))
        XCTAssertNil(ShellCommands.score("lp", in: "pl"))
        let start = ShellCommands.score("lo", in: "panel lotes")!
        let middle = ShellCommands.score("lo", in: "xalxo")!
        XCTAssertGreaterThan(start, middle, "principio de palabra y seguidos puntúan más")
    }

    // MARK: atajos

    func testKeymapIsUniqueAndCoversEveryAction() {
        let ks = ShellKeymap.all
        XCTAssertEqual(Set(ks.map(\.action)), Set(ShellAction.allCases), "un atajo por acción")
        let combos = ks.map { "\($0.shift)\($0.key)" }
        XCTAssertEqual(Set(combos).count, combos.count, "sin atajos repetidos")
        XCTAssertEqual(ShellKeymap.shortcut(for: .prevAttention)?.display, "⇧⌘J")
        XCTAssertEqual(ShellKeymap.shortcut(for: .palette)?.display, "⌘K")
        XCTAssertEqual(ShellKeymap.shortcut(for: .escape)?.display, "Esc")
        XCTAssertFalse(ShellKeymap.shortcut(for: .escape)!.command)
        for p in ShellPanel.allCases { XCTAssertNotNil(ShellAction.allCases.first { $0.panel == p }, "atajo del panel \(p)") }
    }

    // MARK: minimapa y búsqueda por hilo

    func testMinimapFitsAndPicksAProject() throws {
        let state = try XCTUnwrap(CityOfficeFixture.state)
        let model = CityModel.build(state)
        let size = CGSize(width: 184, height: 118)
        let m = ShellMinimap.layout(model, size: size)
        XCTAssertEqual(m.blocks.count, model.buildings.count)
        let bounds = CGRect(origin: .zero, size: size)
        for b in m.blocks { XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(b.rect), "\(b.company) dentro del minimapa") }
        let awesome = try XCTUnwrap(m.blocks.first { $0.company == "awesome-gb" })
        XCTAssertEqual(m.project(at: CGPoint(x: awesome.rect.midX, y: awesome.rect.midY)), "awesome-gb")
        XCTAssertNil(m.project(at: CGPoint(x: -50, y: -50)))
        XCTAssertTrue(ShellMinimap.layout(CityModel(buildings: [], groundX: 1, groundY: 1), size: size).blocks.isEmpty)
    }

    func testShellTaskFindsByTaskOrThread() throws {
        let state = try XCTUnwrap(CityOfficeFixture.state)
        let s = SnapshotMapper.snapshot(state, now: FloorFixture.now)
        XCTAssertEqual(s.shellTask("b")?.task.id, "b")
        XCTAssertEqual(s.shellTask("th-b")?.task.id, "b", "el piso da el hilo; el armazón quiere la tarea")
        XCTAssertEqual(s.shellTask("th-b")?.batch.project, "awesome-gb")
        XCTAssertNil(s.shellTask("no-existe"))
    }
}
