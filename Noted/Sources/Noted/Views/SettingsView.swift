import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var isShowingResetConfirmation = false
    private let labelWidth: CGFloat = 205
    private let controlWidth: CGFloat = 330

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("Transcription Model")
                        .frame(width: labelWidth, alignment: .trailing)
                    HStack(spacing: 10) {
                        Picker("", selection: $settings.transcriptionModel) {
                            ForEach(TranscriptionModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 205, alignment: .leading)

                        Label(
                            settings.selectedModelCacheStatus.displayText,
                            systemImage: settings.selectedModelCacheStatus.systemImage
                        )
                        .foregroundStyle(settings.selectedModelCacheStatus == .missing ? Color.secondary : Color.green)
                        .font(.caption)
                        .frame(width: 110, alignment: .leading)
                    }
                    .frame(width: controlWidth, alignment: .leading)
                }

                GridRow {
                    Text("Locale")
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("", text: $settings.transcriptionLocale)
                        .labelsHidden()
                        .frame(width: controlWidth)
                }

                GridRow {
                    Text("Input Microphone")
                        .frame(width: labelWidth, alignment: .trailing)
                    Picker("", selection: $settings.inputDeviceID) {
                        ForEach(settings.inputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: controlWidth, alignment: .leading)
                }

                GridRow {
                    Text("Record Scheduled Meetings")
                        .frame(width: labelWidth, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("", isOn: $settings.recordScheduledMeetings)
                            .labelsHidden()
                        Text("Toggles calendar-triggered recording when Briefing is installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: controlWidth, alignment: .leading)
                }

                GridRow {
                    Text("Default Directory")
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("", text: $settings.outputDirectoryPath)
                        .labelsHidden()
                        .frame(width: controlWidth)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 22) {
                Button("Open Default Directory") {
                    settings.openOutputDirectory()
                }
                Button("Reset Settings", role: .destructive) {
                    isShowingResetConfirmation = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 28)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(minWidth: 620, minHeight: 310)
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
