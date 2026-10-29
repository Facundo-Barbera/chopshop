import Foundation

// Nombres de pila y subtítulos de los hilos (api_version 3), puro (macOS 13). Todas las vistas (ciudad, oficina, vestíbulo, sala de
// máquinas, inspector) los sacan de aquí para que un hilo se llame igual en todas: el nombre sale del `thread_id` (`HumanNames`) y
// se desambigua dentro del conjunto de hilos que conoce la proyección; el subtítulo es el título del hilo.

extension LiveState {
    /// Lo que se pinta junto a un muñeco o en una fila: "Elena" / "[be] login con passkeys".
    public struct ThreadLabel: Hashable, Sendable {
        public var threadID: String
        public var name: String
        public var subtitle: String
    }

    /// Todos los hilos que nombra la proyección: tareas, ocupantes (y su linaje y herencia), vestíbulo y origen de los runs.
    public var knownThreads: [String] {
        var ids = Set<String>()
        for p in projects {
            for t in p.tasks { if let tid = t["thread_id"]?.string, !tid.isEmpty { ids.insert(tid) } }
            for d in p.office?.desks ?? [] {
                if let o = d.occupant {
                    ids.insert(o.threadID)
                    if let h = o.inheritance?["thread_id"]?.string { ids.insert(h) }
                }
                for l in d.lineage { ids.insert(l.threadID) }
            }
        }
        for e in lobby { ids.insert(e.threadID) }
        for m in machineRoom.rack {
            for r in m["runs"]?.array ?? [] where r["origin"]?["kind"]?.string == "thread" {
                if let id = r["origin"]?["id"]?.string { ids.insert(id) }
            }
        }
        return ids.sorted()
    }

    /// Título más reciente de un hilo: el del ocupante, el del vestíbulo o el de su última `task.state`.
    public func title(ofThread id: String) -> String? {
        for p in projects {
            if let o = p.office?.desk(occupiedBy: id)?.occupant, let t = Self.nonEmpty(o.title) { return t }
        }
        if let t = Self.nonEmpty(lobby.first(where: { $0.threadID == id })?.title) { return t }
        for p in projects {
            if let t = Self.nonEmpty(Self.task(of: id, in: p)?["title"]?.string) { return t }
        }
        // linaje o herencia: el título que quedó guardado
        for p in projects {
            for d in p.office?.desks ?? [] {
                if let h = d.occupant?.inheritance, h["thread_id"]?.string == id, let t = Self.nonEmpty(h["title"]?.string) { return t }
            }
        }
        return nil
    }

    /// Etiquetas de todos los hilos conocidos (calcularlas una vez por cambio de estado: desambiguar mira el conjunto entero).
    public var threadLabels: [String: ThreadLabel] {
        let names = HumanNames.names(for: knownThreads)
        var out: [String: ThreadLabel] = [:]
        for (id, n) in names {
            out[id] = ThreadLabel(threadID: id, name: n, subtitle: HumanNames.subtitle(title: title(ofThread: id), threadID: id))
        }
        return out
    }

    /// Etiqueta de un hilo (si no lo conoce la proyección: el nombre sin desambiguar y el id de subtítulo).
    public func label(ofThread id: String) -> ThreadLabel {
        threadLabels[id] ?? ThreadLabel(threadID: id, name: HumanNames.name(for: id),
                                        subtitle: HumanNames.subtitle(title: title(ofThread: id), threadID: id))
    }
}
