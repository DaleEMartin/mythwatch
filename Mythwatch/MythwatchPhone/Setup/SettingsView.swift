import MythwatchBackend
import MythwatchFeatures
import MythwatchPlayback
import SwiftUI

/// The Settings tab. Its model lives as long as the tab, and is saved when the user leaves the
/// tab if there is something valid to save (as on tvOS; owner, 2026-11-15).
struct SettingsTab: View {
    let app: AppModel
    @State private var model: SettingsViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { SettingsView(model: model) } else { Color.clear }
            }
            .navigationTitle(Labels.settings)
        }
        .onAppear {
            if model == nil { model = app.makeSettingsModel() }
            model?.startDiscovery()
        }
        .onDisappear {
            guard let model else { return }
            model.stopDiscovery()
            if model.canSave { Task { await model.save() } }
        }
    }
}

/// SPEC 7 "Settings": Backend, Playback, Commercials, About.
struct SettingsView: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                TextField(Labels.address, text: $model.addressText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("address.field")
                if let hint = model.addressHint {
                    Text(hint).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("address.hint")
                }
                LabeledContent(Labels.mythTVVersion, value: model.backendInfo?.version.raw ?? Labels.notConnected)
                LabeledContent(Labels.adapter, value: model.adapterName ?? Labels.notConnected)
                Button(Labels.testConnection) { Task { await model.testConnection() } }
                    .disabled(!model.canTestConnection)
                    .accessibilityIdentifier("address.test")
                ConnectionTestResult(test: model.connectionTest, adapterName: model.adapterName)
                if model.isReconnecting {
                    HStack(spacing: 10) { ProgressView(); Text(Labels.reconnecting) }
                }
                if let problem = model.reconnectProblem { MessageBanner(message: problem) }
            } header: {
                Text(Labels.backend)
            } footer: {
                if model.canSave { Text(Labels.savesOnLeaving) }
            }

            if !model.discovered.isEmpty {
                Section(Labels.onYourNetwork) {
                    ForEach(model.discovered) { backend in
                        Button(backend.name) { model.select(backend) }
                    }
                }
            }

            Section(Labels.playback) {
                Picker(Labels.skipForward, selection: $model.skipForwardSeconds) {
                    ForEach(SettingsViewModel.skipForwardChoices, id: \.self) { Text(Labels.seconds($0)).tag($0) }
                }
                Picker(Labels.skipBack, selection: $model.skipBackwardSeconds) {
                    ForEach(SettingsViewModel.skipBackwardChoices, id: \.self) { Text(Labels.seconds($0)).tag($0) }
                }
                Toggle(Labels.deinterlace, isOn: $model.deinterlace)
                Toggle(Labels.askBeforeDelete, isOn: $model.askBeforeDelete)
            }

            Section(Labels.commercials) {
                Picker(Labels.commercialBreaks, selection: $model.commercialSkipMode) {
                    ForEach(CommercialSkipMode.allCases, id: \.self) { Text(Labels.skipMode($0)).tag($0) }
                }
            }

            Section(Labels.about) {
                LabeledContent(Labels.version, value: AboutInfo.version)
                NavigationLink(Labels.licences) { LicencesView() }
                    .accessibilityIdentifier("settings.licences")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("settings.screen")
    }
}

struct LicencesView: View {
    private let paragraphs = AboutInfo.noticeParagraphs

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(paragraphs.indices, id: \.self) { i in
                    Text(paragraphs[i]).font(.footnote).textSelection(.enabled)
                }
            }
            .padding()
        }
        .accessibilityIdentifier("licences.screen")
        .navigationTitle(Labels.licences)
        .navigationBarTitleDisplayMode(.inline)
    }
}
