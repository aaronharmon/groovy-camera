import SwiftUI

/// The R2 bucket and token. They're stored only in this phone's Keychain.
struct SettingsScreen: View {
    let uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = CredentialStore.load() ?? R2Credentials()
    @State private var check: Check = .idle

    private enum Check: Equatable {
        case idle, checking, passed
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Account ID", text: $credentials.accountID)
                    field("Bucket", text: $credentials.bucket)
                    field("Access key ID", text: $credentials.accessKeyID)
                    SecureField("Secret access key", text: $credentials.secretAccessKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Cloudflare R2")
                } footer: {
                    Text("From an R2 API token limited to this bucket, with object read and write. Kept only in this phone's Keychain. The README explains how to make one.")
                }

                Section {
                    Button("Check connection") { Task { await checkConnection() } }
                        .disabled(!credentials.isComplete || check == .checking)
                    switch check {
                    case .idle: EmptyView()
                    case .checking: Text("Checking…").foregroundStyle(.secondary)
                    case .passed: Text("Connected. Uploads will work.").foregroundStyle(.green)
                    case .failed(let problem): Text(problem).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Uploads and deletes a small file under records/.")
                }

                Section("Uploads") {
                    LabeledContent("Waiting", value: "\(uploader.summary.waiting)")
                    LabeledContent("Uploaded", value: "\(uploader.summary.uploaded)")
                    if uploader.summary.needsAttention > 0 {
                        LabeledContent("Need attention", value: "\(uploader.summary.needsAttention)")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onChange(of: credentials) { check = .idle }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func save() {
        guard credentials != CredentialStore.load() ?? R2Credentials() else { return }
        CredentialStore.save(credentials)
        uploader.retryAfterSettingsChange()
    }

    private func checkConnection() async {
        save()
        check = .checking
        if let problem = await R2Client(credentials: credentials).checkConnection() {
            check = .failed(problem)
        } else {
            check = .passed
            uploader.retryAfterSettingsChange()
        }
    }
}
