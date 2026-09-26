import AppKit
import EchoFlowCore
import SwiftUI

@main
@MainActor
struct EchoFlowApp: App {
    @NSApplicationDelegateAdaptor(EchoFlowApplicationDelegate.self) private var applicationDelegate
    @State private var runtime = EchoFlowRuntime()
    @AppStorage("EchoFlow.transcriptionLanguage") private var transcriptionLanguage = ""

    private var speechLocaleIdentifier: String {
        TranscriptionLanguagePreference.resolve(
            transcriptionLanguage,
            systemLanguageIdentifier: Locale.current.identifier
        )
    }

    private var speechPreparationTaskIdentifier: String {
        "\(runtime.modelLibrary.selectedEngineID)|\(speechLocaleIdentifier)"
    }

    var body: some Scene {
        WindowGroup("EchoFlow") {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house") }
                ModelLibraryView()
                    .tabItem { Label("Speech Models", systemImage: "waveform") }
                EchoFlowSettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environment(runtime)
            .navigationTitle("EchoFlow")
            .task(id: speechPreparationTaskIdentifier) {
                guard runtime.modelLibrary.selectedEngineID == ModelSelection.appleSpeechEngineID else { return }
                await runtime.dictation.checkAppleSpeechAssets(localeIdentifier: speechLocaleIdentifier)
            }
        }
        .defaultSize(width: 920, height: 760)
    }
}

@MainActor
final class EchoFlowApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
