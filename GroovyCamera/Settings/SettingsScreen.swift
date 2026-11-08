import SwiftUI

/// The R2 bucket and token. They're stored only in this phone's Keychain.
struct SettingsScreen: View {
    let uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = CredentialStore.load() ?? R2Credentials()
    @State private var check: Check = .idle
    @State private var domain = PhotoDomain.load()
    @State private var keepDays = LocalCopies.keepDays
    @State private var keepOriginals = LocalCopies.keepOriginals

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

                Section {
                    TextField("https://photos.example.com", text: $domain)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let url = PhotoIndex.url(domain: domain) {
                        Link("Open spreadsheet", destination: url)
                        Button("Copy spreadsheet link") { UIPasteboard.general.url = url }
                    }
                } header: {
                    Text("Photo domain")
                } footer: {
                    Text("The bucket's custom domain. The app keeps a spreadsheet of every uploaded photo's link at records/photos.csv, updated after each upload.")
                }

                Section {
                    Stepper(value: $keepDays, in: LocalCopies.dayRange) {
                        LabeledContent("Keep uploaded photos", value: keepDays == 0 ? "No" : "\(keepDays) days")
                    }
                    Toggle("Keep originals", isOn: $keepOriginals)
                } header: {
                    Text("On this phone")
                } footer: {
                    Text("Photos are cleared from the phone once R2 confirms it has them, or after the days set here. Originals are the full-size shots, kept for testing the photo processing.")
                }
                .onChange(of: keepDays) { _, days in
                    LocalCopies.keepDays = days
                    uploader.clearUploaded()
                }
                .onChange(of: keepOriginals) { _, keep in
                    LocalCopies.keepOriginals = keep
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
        if domain.trimmingCharacters(in: .whitespaces) != PhotoDomain.load() {
            PhotoDomain.save(domain)
            uploader.photoDomainChanged()
        }
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
