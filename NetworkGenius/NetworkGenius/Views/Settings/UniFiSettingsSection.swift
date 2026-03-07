import SwiftUI

struct UniFiSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("UniFi Console") {
            TextField("Console URL", text: $viewModel.consoleURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("API Key", text: $viewModel.unifiAPIKey)
                .textContentType(.password)

            TextField("Site ID (optional)", text: $viewModel.siteID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Toggle("Allow Self-Signed Certificates", isOn: $viewModel.allowSelfSignedCerts)

            ConnectionTestButton(viewModel: viewModel)
        }
    }
}
