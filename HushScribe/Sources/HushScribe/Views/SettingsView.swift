import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Transcription Model", selection: $settings.transcriptionModel) {
                ForEach(TranscriptionModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }

            TextField("Locale", text: $settings.transcriptionLocale)

            TextField("Output Directory", text: $settings.outputDirectoryPath)

            Toggle("Hide windows from screen sharing", isOn: $settings.hideFromScreenShare)

            Button("Reset Settings") {
                settings.reset()
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 260)
    }
}
