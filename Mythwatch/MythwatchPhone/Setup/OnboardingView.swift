import MythwatchBackend
import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Onboarding" on a touch screen: discovered backends, an address field, Test Connection
/// and Connect.
struct OnboardingView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Labels.welcomeDetail).foregroundStyle(.secondary)
                }
                if !model.discovered.isEmpty {
                    Section(Labels.onYourNetwork) {
                        ForEach(model.discovered) { backend in
                            Button(backend.name) { model.select(backend) }
                                .accessibilityIdentifier("onboarding.discovered.\(backend.id)")
                        }
                    }
                }
                Section {
                    TextField(Labels.addressPrompt, text: $model.addressText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { if model.canConnect { Task { await model.connect() } } }
                        .accessibilityIdentifier("address.field")
                } footer: {
                    Text(model.addressHint ?? Labels.addressExample)
                        .foregroundStyle(model.addressHint == nil ? Color.secondary : Color.orange)
                        .accessibilityIdentifier("address.hint")
                }
                Section {
                    Button(Labels.testConnection) { Task { await model.testConnection() } }
                        .disabled(!model.canTestConnection)
                        .accessibilityIdentifier("address.test")
                    Button(Labels.connect) { Task { await model.connect() } }
                        .bold()
                        .disabled(!model.canConnect)
                        .accessibilityIdentifier("onboarding.connect")
                    status
                }
            }
            .navigationTitle(Labels.welcome)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.screen")
        .onAppear { model.startDiscovery() }
        .onDisappear { model.stopDiscovery() }
    }

    @ViewBuilder private var status: some View {
        switch model.connectState {
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text(Labels.connectingShort).foregroundStyle(.secondary) }
        case .failed(let message):
            MessageBanner(message: message)
        case .idle, .loaded:
            ConnectionTestResult(test: model.connectionTest, adapterName: model.adapterName)
        }
    }
}

/// What Test Connection found: the version (and host), or why it failed.
struct ConnectionTestResult: View {
    let test: Loadable<BackendInfo>
    let adapterName: String?

    var body: some View {
        switch test {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text(Labels.testing).foregroundStyle(.secondary) }
        case .loaded(let info):
            Label(Labels.found(info, adapter: adapterName), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("address.testResult")
        case .failed(let message):
            MessageBanner(message: message)
        }
    }
}
