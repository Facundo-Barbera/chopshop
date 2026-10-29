import Foundation

/// Qué hilos (`task.state` de la proyección) se pintan como escritorio en la oficina y como ventana en la ciudad. LA regla, una vez:
/// la usan `SnapshotMapper` (oficina y grafo) y `CityModel` (ventanas). Pura: la hora entra por parámetro (en vivo, el reloj del
/// `LiveStore`; en la cronología y los tests, la congelada).
///
/// - Asentado (`phase: settled` o `settled: true`, docs/event-envelope.md): no se pinta nunca. Ya lo guardaste en T3.
/// - Te espera (atención en la cola del proyecto, o `waiting` con `attention`): se pinta siempre, por viejo que sea.
/// - Corriendo o preparándose: se pinta siempre (el agente solo manda `task.state` en las transiciones: un hilo largo
///   puede pasar horas sin sobre y seguir trabajando).
/// - El resto (done, failed, skipped, queued, waiting sin atención): se oculta si su último sobre (`updated`, el `ts` que guarda
///   la proyección) tiene `idleAfter` o más. Sin `updated` se pinta (no se sabe cuándo fue).
public enum ThreadVisibility {
    /// Tiempo sin actividad tras el que un hilo parado deja de pintarse (oficina y ciudad).
    public static let idleAfter: TimeInterval = 2 * 60 * 60

    private static let busy: Set<String> = ["running", "preparing"]

    /// `phase: settled`, o `settled: true` en el cuerpo de `task.state`.
    public static func isSettled(_ t: JSONValue.Object) -> Bool {
        t["phase"]?.string == "settled" || t["settled"]?.bool == true
    }

    /// Último sobre del hilo (`updated` de la proyección).
    public static func lastActivity(_ t: JSONValue.Object) -> Date? { SnapshotMapper.date(t["updated"]?.string) }

    /// La regla. `needsAttention`: el hilo espera algo (atención en la cola, o `waiting` con `attention`).
    public static func isVisible(_ t: JSONValue.Object, needsAttention: Bool, now: Date, idleAfter: TimeInterval = ThreadVisibility.idleAfter) -> Bool {
        if isSettled(t) { return false }
        if needsAttention { return true }
        if let ph = t["phase"]?.string, busy.contains(ph) { return true }
        guard let last = lastActivity(t) else { return true }
        return now.timeIntervalSince(last) < idleAfter
    }

    /// La regla con la atención sacada del proyecto (la misma lectura que `SnapshotMapper.task`).
    public static func isVisible(_ t: JSONValue.Object, in p: LiveState.Project, now: Date, idleAfter: TimeInterval = ThreadVisibility.idleAfter) -> Bool {
        let queued: Bool = t["id"]?.string.map { id in p.attention.contains { $0.key == "task:\(id)" } } ?? false
        let own: Bool = t["phase"]?.string == "waiting" && SnapshotMapper.needs(fromAttention: t["attention"]?.string) != nil
        return isVisible(t, needsAttention: queued || own, now: now, idleAfter: idleAfter)
    }
}
