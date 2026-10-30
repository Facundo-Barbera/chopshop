import Foundation

// Modelos nativos con la misma forma que `chopshop snapshot` / `chopshop metrics` (ver ui/Sources/ChopshopUI/Model.swift
// y ui/web/dev/fixtures.js). Aquí son tipos Swift de verdad; el JSON real se podrá decodificar a ellos más adelante.

public enum Level: String, Sendable { case auto, bot, human }

public enum TaskKind: String, Sendable {
    case running, preparing, done, failed, queued, skipped, ask, approval, human, bot
}

/// Estado que importa para la vista de proyecto (qué corre, qué está trabado, qué te necesita).
public enum TaskState: Int, Sendable, CaseIterable, Comparable {
    case needsYou, stuck, waitingBot, running, queued, done, skipped
    public static func < (a: TaskState, b: TaskState) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self {
        case .needsYou: return "Te necesita"
        case .stuck: return "Trabadas"
        case .waitingBot: return "Esperando a un bot"
        case .running: return "Corriendo"
        case .queued: return "En cola"
        case .done: return "Listas"
        case .skipped: return "Omitidas"
        }
    }
    public var symbol: String {
        switch self {
        case .needsYou: return "person.fill.questionmark"
        case .stuck: return "exclamationmark.triangle.fill"
        case .waitingBot: return "bubble.left.and.bubble.right"
        case .running: return "play.circle.fill"
        case .queued: return "clock"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        }
    }
}

public struct MockQuestion: Hashable, Sendable {
    public var request: String
    public var summary: String
    public var options: [String]
}

public struct MockAnswered: Hashable, Sendable {
    public var summary: String
    public var choice: String
    public var minutesAgo: Int
    public var by: String
}

public struct MockReaction: Hashable, Sendable {
    public var on: String
    public var level: Level
    public var action: String
    public var minutesAgo: Int
    public var note: String?
}

public struct MockTask: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: TaskKind
    public var link: URL?
    public var result: String?
    public var lastError: String?
    public var skipReason: String?
    public var question: MockQuestion?
    public var approvals = 0
    public var level: Level?
    public var escalationReason: String?
    public var botWait: String?
    public var answered: [MockAnswered] = []
    public var reactions: [MockReaction] = []
    /// Hilo de T3 de la tarea (`thread_id` de la proyección); el mundo elige escritorios por hilo, el snapshot va por tarea.
    public var threadID: String?

    public var state: TaskState {
        switch kind {
        case .done: return .done
        case .failed: return .stuck
        case .skipped: return .skipped
        case .queued: return .queued
        case .human, .ask, .approval: return .needsYou
        case .bot: return .waitingBot
        case .running, .preparing: return .running
        }
    }
    public var isPreparing: Bool { kind == .preparing }
}

public struct MockBatch: Identifiable, Hashable, Sendable {
    public var id: String
    public var project: String
    public var host: String
    public var maxParallel: Int
    public var minutesAgo: Int
    public var notes: [String] = []
    public var graph: String?
    public var tasks: [MockTask]
}

public enum NodeStatus: String, Sendable { case done, running, pending, failed, skipped, expanding }

public struct MockGraphNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var parent: String?
    public var depth: Int
    public var kind: String
    public var label: String
    public var title: String
    public var status: NodeStatus
    public var deps: [String] = []
    public var task: String?
    public var result: String?
    public var reason: String?
    public var ask: String?
}

public struct MockGraph: Identifiable, Hashable, Sendable {
    public var id: String
    public var project: String
    public var batch: String
    public var goal: String
    public var status: String
    public var threadBudget: Int
    public var threads: Int
    public var throttleMode: String
    public var nodes: [MockGraphNode]
}

public struct MockEvent: Identifiable, Hashable, Sendable {
    public var id: Int
    public var minutesAgo: Int
    public var event: String
    public var batch: String?
    public var task: String?
    public var summary: String?
}

public struct MockMachine: Identifiable, Hashable, Sendable {
    public var name: String
    public var ok: Bool
    public var stale = false
    public var reason: String?
    public var os: String
    public var role: String
    public var cpus: Int
    public var ramTotalMB: Int
    public var disk: String
    public var diskPct: Int
    public var cpu: [Double]
    public var ram: [Double]
    public var run: [Double]
    public var id: String { name }
    public var cpuNow: Int { Int((cpu.last ?? 0).rounded()) }
    public var ramNow: Int { Int((ram.last ?? 0).rounded()) }
    public var runNow: Int { Int(run.last ?? 0) }
}

/// Resumen por proyecto (equivalente a ProjectInfo + conteos de la vista de proyecto).
public struct ProjectSummary: Identifiable, Hashable, Sendable {
    public var name: String
    public var running: Int
    public var stuck: Int
    public var needsYou: Int
    public var waitingBot: Int
    public var total: Int
    public var id: String { name }
    public var isQuiet: Bool { running + stuck + needsYou + waitingBot == 0 }
}

public struct MockSnapshot: Sendable {
    public var projects: [String]
    public var batches: [MockBatch]
    public var graphs: [MockGraph]
    public var events: [MockEvent]
    public var machines: [MockMachine]

    public func batches(of project: String) -> [MockBatch] { batches.filter { $0.project == project } }
    public func graphs(of project: String) -> [MockGraph] { graphs.filter { $0.project == project } }
    public func graph(for project: String) -> MockGraph? { graphs.first { $0.project == project } }
    public func tasks(of project: String) -> [MockTask] { batches(of: project).flatMap(\.tasks) }

    public func summary(of project: String) -> ProjectSummary {
        let ts = tasks(of: project)
        func n(_ s: TaskState) -> Int { ts.filter { $0.state == s }.count }
        return ProjectSummary(name: project, running: n(.running), stuck: n(.stuck), needsYou: n(.needsYou),
                              waitingBot: n(.waitingBot), total: ts.count)
    }
    public var summaries: [ProjectSummary] {
        projects.map(summary(of:)).sorted { ($0.isQuiet ? 1 : 0, $0.name) < ($1.isQuiet ? 1 : 0, $1.name) }
    }
}
