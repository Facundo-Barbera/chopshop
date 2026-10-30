import Foundation

public enum Fixtures {
    public static let projects = ["bixku-utilities", "nuskills", "chopshop"]

    private static func link(_ id: String) -> URL? { URL(string: "https://t3.example/thread/\(id)") }

    private static func t(_ id: String, _ title: String, _ kind: TaskKind, q: String? = nil, opts: [String]? = nil,
                          result: String? = nil, error: String? = nil, level: Level? = nil) -> MockTask {
        var x = MockTask(id: id, title: title, kind: kind, link: link(id))
        x.result = result
        switch kind {
        case .queued: x.link = nil
        case .skipped: x.link = nil; x.skipReason = "dependencia fallida"
        case .failed: x.lastError = error ?? "Las pruebas fallaron tras el rebase (3 fallos en parser.test.ts)"
        case .ask:
            x.question = MockQuestion(request: "rq-\(id)", summary: q ?? "¿Qué estrategia prefieres?", options: opts ?? ["Opción A", "Opción B"])
            x.level = level
        case .approval: x.approvals = 1
        case .human:
            x.level = .human
            x.question = MockQuestion(request: "rq-\(id)", summary: q ?? "¿Cambio de API público?", options: opts ?? ["Sí, romper", "No, mantener"])
            x.escalationReason = "decisión de producto: afecta la API pública"
        case .bot:
            x.level = .bot
            x.question = MockQuestion(request: "rq-\(id)", summary: q ?? "¿Qué versión mínima soportamos?", options: ["18", "20"])
            x.botWait = "bot-bixku"
        default: break
        }
        if let error, kind != .failed { x.lastError = error }
        return x
    }

    public static var snapshot: MockSnapshot {
        let bixku = [
            t("t-0041", "Migrar utilidades de fechas a Temporal", .running),
            t("t-0042", "Pruebas unitarias del parser de CSV", .done, result: "Agregué 14 pruebas; cobertura del parser 71% → 94%. Sin cambios de comportamiento."),
            t("t-0043", "Decidir compatibilidad con Node 18 en slugify()", .ask, q: "¿Mantenemos soporte de Node 18 en slugify()?", opts: ["Mantener", "Subir mínimo a Node 20"]),
            t("t-0044", "Documentar API de formatBytes", .queued),
        ]
        var bixkuOld = [
            t("t-0035", "Extraer helpers de URL a paquete propio", .done, result: "Listo: paquete `@bixku/url` con 6 helpers y README."),
            t("t-0036", "Quitar dependencia lodash", .done, result: "Reemplazado por 3 funciones locales. Bundle −38 KB."),
            t("t-0037", "Arreglar redondeo en currency()", .failed),
        ]
        bixkuOld[1].answered = [MockAnswered(summary: "¿Reemplazar lodash por funciones propias?", choice: "Sí", minutesAgo: 190, by: "humano")]

        var nusk = [
            t("t-0051", "Triage: un nodo por bug", .done, result: "[{\"bug\":\"BUG-1\",\"depends_on\":[]}]"),
            t("t-0052", "BUG-1 · Lección no guarda progreso al salir", .done, result: "RESULT: guardar progreso en onBeforeUnload."),
            t("t-0053", "BUG-2 · Quiz duplica preguntas", .done, result: "RESULT: deduplicar por id antes de barajar."),
            t("t-0054", "BUG-3 · Racha se reinicia por zona horaria", .running),
            t("t-0055", "BUG-5.1 · Migrar fechas de racha a UTC", .running),
            t("t-0056", "BUG-6 · Certificado con nombre vacío", .human, q: "¿El certificado debe permitir nombre vacío?", opts: ["Bloquear", "Usar correo"]),
            t("t-0057", "BUG-8 · Notificación push llega 2 veces", .bot, q: "¿Qué canal manda la fuente de verdad?", opts: ["FCM", "APNs"]),
            t("t-0058", "BUG-9 · Búsqueda ignora acentos", .failed, error: "El hilo se interrumpió: sin progreso en 20 min"),
        ]
        nusk[5].reactions = [MockReaction(on: "pending_question", level: .human, action: "escalar a Facundo", minutesAgo: 9, note: "decisión de producto")]
        nusk[6].reactions = [MockReaction(on: "pending_question", level: .bot, action: "despertar a bot-nuskills", minutesAgo: 14, note: "pregunta técnica")]
        nusk[7].reactions = [MockReaction(on: "task_stalled", level: .auto, action: "retry_once", minutesAgo: 33, note: nil),
                             MockReaction(on: "task_failed", level: .auto, action: "retry_once agotado", minutesAgo: 31, note: nil)]
        nusk[2].reactions = [MockReaction(on: "task_done", level: .auto, action: "settle", minutesAgo: 22, note: nil)]
        nusk[1].answered = [MockAnswered(summary: "¿Guardar progreso local o en servidor?", choice: "Local + sync", minutesAgo: 80, by: "bot-nuskills")]
        nusk[6].botWait = "bot-nuskills"

        let nuskOld = [
            t("t-0044b", "Actualizar dependencias de seguridad", .done, result: "12 paquetes actualizados, auditoría sin vulnerabilidades altas."),
            t("t-0045b", "Eliminar código muerto en /legacy", .done, result: "Eliminados 1,240 líneas; build y pruebas verdes."),
        ]
        let chop = [
            t("t-0061", "chopshop integrate: cola local de aterrizaje", .running),
            t("t-0062", "Verificador con otro modelo: escenarios ocultos", .approval),
            t("t-0063", "Cliente MCP de T3 con OAuth PKCE", .done, result: "chopshop/t3mcp.py listo; credencial 0600 en ~/.chopshop."),
            t("t-0064", "Registro de agente por máquina", .preparing),
        ]

        func mk(_ id: String, _ p: String, _ host: String, _ ago: Int, _ tasks: [MockTask], par: Int = 2, notes: [String] = [], graph: String? = nil) -> MockBatch {
            MockBatch(id: id, project: p, host: host, maxParallel: par, minutesAgo: ago, notes: notes, graph: graph, tasks: tasks)
        }
        let batches = [
            mk("b-0007", "bixku-utilities", "mini-fbarbera", 70, bixku, notes: ["lote de limpieza semanal"]),
            mk("b-0006", "bixku-utilities", "mini-fbarbera", 260, bixkuOld),
            mk("b-0005", "nuskills", "contabo-dev", 95, nusk, par: 4, graph: "g-0003"),
            mk("b-0004", "nuskills", "contabo-dev", 600, nuskOld),
            mk("b-0003", "chopshop", "contabo-dev", 150, chop),
        ]
        return MockSnapshot(projects: projects, batches: batches, graphs: [graph(threads: nusk.count), bixkuGraph, chopGraph], events: events, machines: machines)
    }

    static var bixkuGraph: MockGraph {
        let nodes = [
            MockGraphNode(id: "n0", parent: nil, depth: 0, kind: "root", label: "meta", title: "Limpieza semanal de utilidades", status: .expanding),
            MockGraphNode(id: "n1", parent: "n0", depth: 1, kind: "task", label: "CSV", title: "Pruebas unitarias del parser de CSV", status: .done, task: "t-0042"),
            MockGraphNode(id: "n2", parent: "n0", depth: 1, kind: "task", label: "Temporal", title: "Migrar utilidades de fechas a Temporal", status: .running, task: "t-0041"),
            MockGraphNode(id: "n3", parent: "n0", depth: 1, kind: "task", label: "slugify", title: "Compatibilidad con Node 18", status: .running, task: "t-0043", ask: "¿Mantenemos soporte de Node 18?"),
            MockGraphNode(id: "n4", parent: "n0", depth: 1, kind: "task", label: "formatBytes", title: "Documentar API de formatBytes", status: .pending, deps: ["n2"], task: "t-0044", reason: "espera a Temporal"),
        ]
        return MockGraph(id: "g-0007", project: "bixku-utilities", batch: "b-0007", goal: "Limpieza semanal de utilidades", status: "running", threadBudget: 6, threads: 4, throttleMode: "completo", nodes: nodes)
    }

    static var chopGraph: MockGraph {
        let nodes = [
            MockGraphNode(id: "n0", parent: nil, depth: 0, kind: "root", label: "meta", title: "Cola de aterrizaje y verificador", status: .expanding),
            MockGraphNode(id: "n1", parent: "n0", depth: 1, kind: "task", label: "MCP", title: "Cliente MCP de T3 con OAuth PKCE", status: .done, task: "t-0063"),
            MockGraphNode(id: "n2", parent: "n0", depth: 1, kind: "task", label: "integrate", title: "Cola local de aterrizaje", status: .running, deps: ["n1"], task: "t-0061"),
            MockGraphNode(id: "n3", parent: "n0", depth: 1, kind: "task", label: "agente", title: "Registro de agente por máquina", status: .running, deps: ["n1"], task: "t-0064"),
            MockGraphNode(id: "n4", parent: "n0", depth: 1, kind: "task", label: "verificador", title: "Escenarios ocultos con otro modelo", status: .running, deps: ["n2"], task: "t-0062", ask: "Permiso para ejecutar pytest"),
        ]
        return MockGraph(id: "g-0003c", project: "chopshop", batch: "b-0003", goal: "Cola de aterrizaje y verificador", status: "running", threadBudget: 6, threads: 4, throttleMode: "completo", nodes: nodes)
    }

    static let events: [MockEvent] = [
        MockEvent(id: 1, minutesAgo: 2, event: "pending_question", batch: "b-0007", task: "t-0043", summary: "¿Mantenemos soporte de Node 18 en slugify()?"),
        MockEvent(id: 2, minutesAgo: 5, event: "pending_approval", batch: "b-0003", task: "t-0062", summary: "Permiso para ejecutar pytest"),
        MockEvent(id: 3, minutesAgo: 9, event: "reaction", batch: "b-0005", task: "t-0056", summary: "Escalada a Facundo"),
        MockEvent(id: 4, minutesAgo: 14, event: "pending_question", batch: "b-0005", task: "t-0057", summary: "¿Qué canal manda la fuente de verdad?"),
        MockEvent(id: 5, minutesAgo: 22, event: "task_done", batch: "b-0005", task: "t-0053", summary: nil),
        MockEvent(id: 6, minutesAgo: 31, event: "task_done", batch: "b-0005", task: "t-0058", summary: "falló"),
        MockEvent(id: 7, minutesAgo: 48, event: "task_done", batch: "b-0007", task: "t-0042", summary: nil),
        MockEvent(id: 8, minutesAgo: 75, event: "batch_done", batch: "b-0006", task: nil, summary: "2 de 3 tareas completadas"),
        MockEvent(id: 9, minutesAgo: 130, event: "task_done", batch: "b-0003", task: "t-0063", summary: nil),
    ]

    static func graph(threads: Int) -> MockGraph {
        typealias N = MockGraphNode
        func n(_ id: String, _ parent: String?, _ depth: Int, _ kind: String, _ label: String, _ title: String, _ st: NodeStatus,
               deps: [String] = [], task: String? = nil, result: String? = nil, reason: String? = nil, ask: String? = nil) -> N {
            N(id: id, parent: parent, depth: depth, kind: kind, label: label, title: title, status: st, deps: deps, task: task, result: result, reason: reason, ask: ask)
        }
        let nodes = [
            n("n0", nil, 0, "root", "meta", "Resolver los bugs de la app de lecciones", .expanding),
            n("n1", "n0", 1, "triage", "triage", "Triage: un nodo por bug", .done, task: "t-0051"),
            n("n2", "n0", 1, "bug", "BUG-1", "Lección no guarda progreso al salir", .done, task: "t-0052", result: "guardar progreso en onBeforeUnload"),
            n("n3", "n0", 1, "bug", "BUG-2", "Quiz duplica preguntas", .done, task: "t-0053", result: "deduplicar por id antes de barajar"),
            n("n4", "n0", 1, "bug", "BUG-3", "Racha se reinicia por zona horaria", .running, task: "t-0054"),
            n("n5", "n0", 1, "bug", "BUG-4", "Gráfica de racha muestra día incorrecto", .pending, deps: ["n4"], reason: "espera a BUG-3"),
            n("n6", "n0", 1, "bug", "BUG-5", "Fechas de racha inconsistentes", .expanding, reason: "dividido en 2 subtareas"),
            n("n7", "n6", 2, "bug", "BUG-5.1", "Migrar fechas de racha a UTC", .running, task: "t-0055"),
            n("n8", "n6", 2, "bug", "BUG-5.2", "Actualizar pruebas de fechas", .pending, deps: ["n7"]),
            n("n9", "n0", 1, "bug", "BUG-6", "Certificado con nombre vacío", .running, task: "t-0056", ask: "¿El certificado debe permitir nombre vacío?"),
            n("n10", "n0", 1, "bug", "BUG-8", "Notificación push llega 2 veces", .running, task: "t-0057", ask: "¿Qué canal manda la fuente de verdad?"),
            n("n11", "n0", 1, "bug", "BUG-9", "Búsqueda ignora acentos", .failed, task: "t-0058", reason: "sin progreso en 20 min"),
            n("n12", "n0", 1, "bug", "BUG-10", "Exportar progreso a CSV", .skipped, deps: ["n11"], reason: "dependencia fallida"),
        ]
        return MockGraph(id: "g-0003", project: "nuskills", batch: "b-0005", goal: "Resolver los bugs de la app de lecciones",
                         status: "running", threadBudget: 12, threads: threads, throttleMode: "mitad", nodes: nodes)
    }

    static func series(base: Double, amp: Double, phase: Double, n: Int = 60) -> [Double] {
        (0..<n).map { i in
            let v = base + amp * sin(Double(i) / 6 + phase) + amp * 0.35 * sin(Double(i) * 1.7 + phase * 2)
            return min(100, max(3, v)).rounded()
        }
    }

    static var machines: [MockMachine] {
        [
            MockMachine(name: "mini-fbarbera", ok: true, os: "macOS 26", role: "dev", cpus: 10, ramTotalMB: 16384, disk: "412G de 926G", diskPct: 45,
                        cpu: series(base: 28, amp: 12, phase: 0.4), ram: series(base: 58, amp: 3, phase: 1.2), run: Array(repeating: 1, count: 60)),
            MockMachine(name: "contabo-dev", ok: true, os: "Ubuntu 24.04", role: "tests-only", cpus: 8, ramTotalMB: 32768, disk: "310G de 400G", diskPct: 78,
                        cpu: series(base: 71, amp: 14, phase: 2.1), ram: series(base: 64, amp: 4, phase: 0.2), run: Array(repeating: 3, count: 60)),
            MockMachine(name: "macbook-air", ok: false, stale: true, reason: "sin datos hace 3 h", os: "macOS 26", role: "dev", cpus: 8, ramTotalMB: 16384,
                        disk: "", diskPct: 0, cpu: [], ram: [], run: Array(repeating: 0, count: 60)),
        ]
    }
}
