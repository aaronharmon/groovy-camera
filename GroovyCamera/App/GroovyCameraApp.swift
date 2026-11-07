import SwiftData
import SwiftUI

@main
struct GroovyCameraApp: App {
    private let container: ModelContainer
    /// Made once, here. SwiftUI can run a view's initializer again at any time, and a second
    /// session controller would run launch recovery against the live session, deleting the photo
    /// still being saved and its record.
    private let model: CameraModel

    init() {
        do {
            container = try ModelContainer(for: Record.self, Photo.self)
        } catch {
            fatalError("Couldn't open the app's records: \(error)")
        }
        model = CameraModel(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model)
        }
    }
}
