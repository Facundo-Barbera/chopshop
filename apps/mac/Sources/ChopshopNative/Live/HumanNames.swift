import Foundation

/// Nombre de pila para cada hilo de T3: la oficina la habitan personas, no ids. El nombre sale solo del `thread_id` (FNV-1a, igual
/// en cada proceso y en cada vista: ciudad, oficina, vestíbulo, inspector y sala de máquinas); el título del hilo va debajo como
/// subtítulo. Si dos hilos de la misma vista caen en el mismo nombre, los dos llevan una inicial (también fija por hilo).
public enum HumanNames {
    /// 64 nombres cortos (se leen en una etiqueta de 10 pt), mezclados y sin repetir inicial+nombre.
    public static let pool: [String] = [
        "Ana", "Bruno", "Carla", "Diego", "Elena", "Fermín", "Gala", "Hugo",
        "Inés", "Joaquín", "Karen", "Lucas", "Marta", "Nicolás", "Olga", "Pablo",
        "Quique", "Rocío", "Sergio", "Tamara", "Ulises", "Valeria", "Walter", "Ximena",
        "Yago", "Zoe", "Abril", "Bautista", "Camila", "Darío", "Emma", "Felipe",
        "Gema", "Héctor", "Irene", "Julián", "Lara", "Mateo", "Nora", "Óscar",
        "Paula", "Ramiro", "Sofía", "Tomás", "Úrsula", "Vicente", "Alma", "Bruna",
        "Ciro", "Delfina", "Esteban", "Flor", "Gonzalo", "Helena", "Iker", "Jimena",
        "León", "Mía", "Noel", "Olivia", "Pilar", "Rafael", "Sara", "Teo",
    ]

    /// Nombre del hilo (sin desambiguar).
    public static func name(for threadID: String) -> String {
        pool[Int(CityLights.hash(threadID) % UInt64(pool.count))]
    }

    /// Inicial fija del hilo ("B."), para separar dos hilos con el mismo nombre.
    public static func initial(for threadID: String) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPRSTUVZ")
        let h = CityLights.hash("inicial#" + threadID)
        return "\(letters[Int(h % UInt64(letters.count))])."
    }

    /// Nombres de un conjunto de hilos que se ven juntos: los que chocan llevan su inicial.
    public static func names(for threadIDs: [String]) -> [String: String] {
        var byName: [String: [String]] = [:]
        for id in Set(threadIDs) { byName[name(for: id), default: []].append(id) }
        var out: [String: String] = [:]
        for (n, ids) in byName {
            for id in ids { out[id] = ids.count > 1 ? "\(n) \(initial(for: id))" : n }
        }
        return out
    }

    /// Subtítulo: el título del hilo (o el id si T3 aún no le puso título).
    public static func subtitle(title: String?, threadID: String) -> String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return threadID
    }
}
