import SwiftUI

/// La oficina de un proyecto: sus pisos (`ProjectOffice.floors`: vestíbulo y pisos de escritorios por rol) con un selector de
/// piso abajo a la izquierda (no mueve el encuadre: la ciudad hace el zoom al mismo piso que se monta aquí). Un piso cada vez,
/// pintado por `FloorOfficeView`.
@available(macOS 26.0, *)
public struct ProjectOfficeView: View {
    let floors: [FloorPlan]
    var frozenNow: Date?
    var flatChrome: Bool
    var onInspect: ((String) -> Void)?
    @State private var pick: Int

    /// `initial`: índice del piso con el que abrir (nil = `ProjectOffice.initialIndex`).
    public init(floors: [FloorPlan], initial: Int? = nil, frozenNow: Date? = nil, flatChrome: Bool = false, onInspect: ((String) -> Void)? = nil) {
        self.floors = floors; self.frozenNow = frozenNow; self.flatChrome = flatChrome; self.onInspect = onInspect
        _pick = State(initialValue: initial ?? ProjectOffice.initialIndex(floors, now: frozenNow ?? Date()))
    }

    private var index: Int { min(max(0, pick), max(0, floors.count - 1)) }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            if floors.isEmpty {
                VStack(spacing: 6) {
                    Text("Nadie en la oficina").font(.system(size: 15, weight: .medium))
                    Text("Los hilos que corren aparecen aquí; los terminados se desvanecen y salen.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FloorOfficeView(plan: floors[index], frozenNow: frozenNow, flatChrome: flatChrome, onInspect: onInspect)
                    .id(floorKey(floors[index]))
                if floors.count > 1 {
                    FloorTabs(titles: floors.map(tabTitle), pick: $pick, flat: flatChrome)
                        .padding(.leading, 14).padding(.bottom, 12)
                }
            }
        }
    }

    private func floorKey(_ f: FloorPlan) -> String {
        f.kind == .lobby ? "lobby:\(f.name ?? "")" : "floor:\(f.floorIndex)"
    }

    private func tabTitle(_ f: FloorPlan) -> String {
        let now = frozenNow ?? Date()
        let n = f.kind == .lobby ? f.lobby.filter { !$0.gone(at: now) }.count : f.desks.filter { f.occupant(of: $0.id, now: now) != nil }.count
        return n > 0 ? "\(f.shortTitle) · \(n)" : f.shortTitle
    }
}

/// Selector de piso: segmentado nativo; en capturas headless (ImageRenderer no dibuja controles de AppKit), pintado a mano.
@available(macOS 26.0, *)
struct FloorTabs: View {
    let titles: [String]
    @Binding var pick: Int
    let flat: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if flat {
            HStack(spacing: 0) {
                ForEach(titles.indices, id: \.self) { i in
                    Text(titles[i]).font(.system(size: 11.5, weight: i == pick ? .semibold : .regular))
                        .padding(.horizontal, 11).padding(.vertical, 3)
                        .background { if i == pick { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.95)).shadow(color: .black.opacity(0.15), radius: 1, y: 0.5) } }
                        .foregroundStyle(i == pick ? Color.primary : Color.secondary)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
        } else {
            Picker("Piso", selection: $pick) { ForEach(titles.indices, id: \.self) { Text(titles[$0]).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}
