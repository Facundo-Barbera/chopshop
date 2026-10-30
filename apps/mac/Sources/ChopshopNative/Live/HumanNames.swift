import Foundation

public enum HumanNames {
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

    public static func name(for threadID: String) -> String {
        pool[Int(CityLights.hash(threadID) % UInt64(pool.count))]
    }

    public static func initial(for threadID: String) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPRSTUVZ")
        let h = CityLights.hash("inicial#" + threadID)
        return "\(letters[Int(h % UInt64(letters.count))])."
    }

    public static func names(for threadIDs: [String]) -> [String: String] {
        var byName: [String: [String]] = [:]
        for id in Set(threadIDs) { byName[name(for: id), default: []].append(id) }
        var out: [String: String] = [:]
        for (n, ids) in byName {
            for id in ids { out[id] = ids.count > 1 ? "\(n) \(initial(for: id))" : n }
        }
        return out
    }

    public static func subtitle(title: String?, threadID: String) -> String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return threadID
    }
}
