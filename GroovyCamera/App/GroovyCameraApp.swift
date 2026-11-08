import SwiftData
import SwiftUI
import UIKit

@main
struct GroovyCameraApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, phase in
            // Picks up anything interrupted, such as uploads cancelled by a force-quit.
            if phase == .active { model.uploader.schedule() }
        }
    }
}

/// Only here for background upload results, which iOS reports through the app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // The uploader's session already exists: the app creates it at launch, before this.
        BackgroundUploads.completionHandler = completionHandler
    }
}
