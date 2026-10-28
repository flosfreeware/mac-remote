import SwiftUI

@main
struct MacRemoteClientApp: App {
    @StateObject private var remote = RemoteConnection()
    var body: some Scene { WindowGroup { ContentView().environmentObject(remote) } }
}
