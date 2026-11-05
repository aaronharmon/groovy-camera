import SwiftData
import SwiftUI

@main
struct GroovyCameraApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Record.self, Photo.self)
        } catch {
            fatalError("Couldn't open the app's records: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(context: container.mainContext)
        }
    }
}
