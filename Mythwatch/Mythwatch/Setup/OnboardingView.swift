import MythwatchBackend
import MythwatchFeatures
import SwiftUI

/// SPEC 7 "Onboarding": discovered backends, an address field, Test Connection and Connect.
struct OnboardingView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(spacing: 36) {
            Text(Labels.welcome).font(.largeTitle).bold()
            Text(Labels.welcomeDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)

            if !model.discovered.isEmpty {
                VStack(spacing: 16) {
                    Text(Labels.onYourNetwork).font(.headline)
                    HStack(spacing: 30) {
                        ForEach(model.discovered) { backend in
                            Button(backend.name) { model.select(backend) }
                                .accessibilityIdentifier("onboarding.discovered.\(backend.id)")
                        }
                    }
                }
                .focusSection()
            }

            VStack(spacing: 12) {
                TextField(Labels.addressPrompt, text: $model.addressText)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(width: 900)
                    .accessibilityIdentifier("address.field")
                Text(model.addressHint ?? Labels.addressExample)
                    .font(.callout)
                    .foregroundStyle(model.addressHint == nil ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("address.hint")
            }

            HStack(spacing: 30) {
                Button(Labels.testConnection) { Task { await model.testConnection() } }
                    .disabled(!model.canTestConnection)
                    .accessibilityIdentifier("address.test")
                Button(Labels.connect) { Task { await model.connect() } }
                    .disabled(!model.canConnect)
                    .accessibilityIdentifier("onboarding.connect")
            }
            .focusSection()

            status.frame(minHeight: 140)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.screen")
        .onAppear { model.startDiscovery() }
        .onDisappear { model.stopDiscovery() }
    }

    @ViewBuilder private var status: some View {
        switch model.connectState {
        case .loading:
            LoadingView(caption: Labels.connectingShort).frame(maxHeight: 140)
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
            HStack(spacing: 16) { ProgressView(); Text(Labels.testing).foregroundStyle(.secondary) }
        case .loaded(let info):
            Label(Labels.found(info, adapter: adapterName), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("address.testResult")
        case .failed(let message):
            MessageBanner(message: message)
        }
    }
}
