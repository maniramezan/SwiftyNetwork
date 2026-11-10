import AppFramework
import OtherFramework
import SwiftUI

@main
struct IntegrationHost: App {
    var body: some Scene {
        WindowGroup {
            Text(otherFrameworkHasError() ? "Ready" : "Error")
        }
    }
}
