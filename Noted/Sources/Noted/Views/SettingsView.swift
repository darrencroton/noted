import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var isShowingResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("Transcription Model")
                        .frame(width: 170, alignment: .trailing)
                    HStack(spacing: 10) {
                        Picker("", selection: $settings.transcriptionModel) {
                            ForEach(TranscriptionModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 185, alignment: .leading)

                        Label(
                            settings.selectedModelCacheStatus.displayText,
                            systemImage: settings.selectedModelCacheStatus.systemImage
                        )
                        .foregroundStyle(settings.selectedModelCacheStatus == .missing ? Color.secondary : Color.green)
                        .font(.caption)
                        .frame(width: 95, alignment: .leading)
                    }
                    .frame(width: 300, alignment: .leading)
                }

                GridRow {
                    Text("Locale")
                        .frame(width: 170, alignment: .trailing)
                    TextField("", text: $settings.transcriptionLocale)
                        .labelsHidden()
                        .frame(width: 260)
                }

                GridRow {
                    Text("Input Microphone")
                        .frame(width: 170, alignment: .trailing)
                    Picker("", selection: $settings.inputDeviceID) {
                        ForEach(settings.inputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)
                }

                GridRow {
                    Text("Auto-ingest to Briefing")
                        .frame(width: 170, alignment: .trailing)
                    Toggle("", isOn: $settings.ingestAfterCompletion)
                        .labelsHidden()
                        .frame(width: 260, alignment: .leading)
                }

                GridRow {
                    Text("Default Directory")
                        .frame(width: 170, alignment: .trailing)
                    TextField("", text: $settings.outputDirectoryPath)
                        .labelsHidden()
                        .frame(width: 260)
                }
            }

            HStack(spacing: 22) {
                Button("Open Default Directory") {
                    settings.openOutputDirectory()
                }
                Button("Reset Settings", role: .destructive) {
                    isShowingResetConfirmation = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(minWidth: 560, minHeight: 225)
        .onAppear {
            settings.refreshInputDevices()
        }
        .alert("Reset settings?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                settings.reset()
            }
        } message: {
            Text("This will restore noted's default settings.")
        }
    }
}
