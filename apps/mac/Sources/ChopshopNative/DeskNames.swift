import Foundation

/// Nombre de pila para cada escritorio de la oficina, sacado del id (nodo o hilo). Puro y determinista: el mismo id da el mismo
/// nombre en cada ejecución y en cada Mac. Por eso el hash es FNV-1a de 64 bits sobre los bytes UTF-8, y no `hashValue` (Swift lo
/// siembra distinto en cada proceso).
///
/// - `name(for:)`: el nombre preferido de un id suelto (`pool[fnv % pool.count]`). Puede repetirse entre ids.
/// - `assign(_:)`: los nombres de toda una oficina, sin repetir. Recorre los ids ordenados; cada uno toma su nombre preferido y,
///   si ya está tomado, el siguiente libre de `pool` (sondeo lineal). Si hay más escritorios que nombres, al preferido se le suma
///   un número (" 2", " 3"...).
///
/// Estabilidad: un escritorio conserva su nombre aunque lleguen o se vayan otros, salvo que haya chocado (que su preferido, o un
/// nombre de su sondeo, lo tomara o lo suelte otro id que va antes en el orden).
public enum DeskNames {
    /// Lista fija de nombres de pila (orden estable: cambiarlo renombra a todos).
    public static let pool: [String] = [
        "Ana", "Bruno", "Lucía", "Mateo", "Sofía", "Tomás", "Valeria", "Diego",
        "Emma", "Leo", "Nora", "Iván", "Julia", "Hugo", "Clara", "Pablo",
        "Maya", "Omar", "Elena", "Sam", "Carla", "Martín", "Inés", "Joaquín",
        "Paula", "Nico", "Lara", "Andrés", "Irene", "Raúl", "Marta", "Simón",
        "Alba", "Gael", "Vera", "Luca", "Olivia", "Noah", "Mía", "Liam",
        "Zoe", "Max", "Ada", "Theo", "Ivy", "Felix", "Rosa", "Pedro",
        "Nina", "Óscar", "Eva", "Adrián", "Lola", "Marco", "Kai", "Yara",
        "Ravi", "Aisha", "Kenji", "Lina", "Amir", "Sara", "Jonas", "Celia",
    ]

    /// Nombre estable para un escritorio (id del nodo/hilo). Determinista entre ejecuciones y máquinas.
    public static func name(for id: String) -> String { pool[slot(for: id)] }

    /// Nombres para todos los escritorios de una oficina, sin repetir mientras quepan en `pool`.
    public static func assign(_ ids: [String]) -> [String: String] {
        let n: Int = pool.count
        var used: Set<String> = []
        var out: [String: String] = [:]
        for id in Set(ids).sorted() {
            let start: Int = slot(for: id)
            var picked: String? = nil
            for k in 0..<n where !used.contains(pool[(start + k) % n]) {
                picked = pool[(start + k) % n]
                break
            }
            if picked == nil {
                // sin nombres libres: el preferido con el primer número que nadie tenga
                var suffix: Int = 2
                while used.contains("\(pool[start]) \(suffix)") { suffix += 1 }
                picked = "\(pool[start]) \(suffix)"
            }
            let name: String = picked!
            used.insert(name)
            out[id] = name
        }
        return out
    }

    /// Posición preferida del id en `pool`.
    static func slot(for id: String) -> Int { Int(fnv1a64(id) % UInt64(pool.count)) }

    /// FNV-1a de 64 bits sobre los bytes UTF-8 (operaciones con desborde: `&*`).
    static func fnv1a64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
