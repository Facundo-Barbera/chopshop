import SwiftUI
#if DEBUG && HOT_RELOAD
@_exported import Inject
#endif

extension View {
    #if DEBUG && HOT_RELOAD
    public func hotReload() -> some View { enableInjection() }
    #else
    @inline(__always) public func hotReload() -> Self { self }
    #endif
}
