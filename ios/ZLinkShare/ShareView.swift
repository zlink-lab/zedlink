import SwiftUI

/// Connection → host → workspace → thread (recent first, or a new one), a comment, then Send.
struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                itemsSection
                destinationSection
                threadSection
                statusSection
            }
            .navigationTitle("Send to Zed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.done ? "Close" : "Cancel") {
                        if model.done { model.finish?(false) } else { model.cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.sending ? "Sending…" : "Send") { Task { await model.send() } }
                        .disabled(!model.canSend)
                }
            }
            .onChange(of: model.profileID) { _, _ in Task { await model.profileChanged() } }
            .onChange(of: model.targetID) { old, new in if !old.isEmpty && !new.isEmpty { Task { await model.targetChanged() } } }
            .onChange(of: model.hostID) { _, _ in model.hostChanged() }
            .onChange(of: model.projectID) { _, _ in model.rebuildThreads() }
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(model.files) { file in
                Label("📎 \(file.fileName) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))",
                      systemImage: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
                    .lineLimit(1).truncationMode(.middle)
            }
            TextField("Comment for the agent", text: $model.comment, axis: .vertical)
                .lineLimit(2...8)
        } header: {
            Text("Sharing")
        } footer: {
            if model.totalBytes > ShareModel.handoffBytes {
                Text("Large files are handed to ZLink Lab, which uploads them when you open it.")
            }
        }
    }

    @ViewBuilder private var destinationSection: some View {
        Section("Send to") {
            if model.profiles.count > 1 {
                Picker("Connection", selection: $model.profileID) {
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id.uuidString) }
                }
            } else if let profile = model.profile {
                LabeledContent("Connection", value: profile.name)
            }
            if model.targets.filter(\.available).count > 1 {
                Picker("Zed", selection: $model.targetID) {
                    ForEach(model.targets.filter(\.available)) { target in Text(target.label).tag(target.id) }
                }
            }
            if !model.hosts.isEmpty {
                Picker("Host", selection: $model.hostID) {
                    ForEach(model.hosts) { host in Text(host.label).tag(host.id) }
                }
            }
            if let host = model.host {
                Picker("Workspace", selection: $model.projectID) {
                    ForEach(host.projects) { project in
                        Text(project.open ? project.name : project.name + " · closed").tag(project.id)
                    }
                }
            }
            if model.loading { ProgressView() }
        }
    }

    @ViewBuilder private var threadSection: some View {
        if model.project != nil {
            Section("Thread") {
                Picker("Thread", selection: $model.threadChoice) {
                    Label("New thread", systemImage: "plus.bubble").tag(ShareModel.newThread)
                    ForEach(model.threads) { thread in
                        VStack(alignment: .leading) {
                            Text(thread.title)
                            if let date = thread.updatedAt {
                                Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(thread.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        if !model.status.isEmpty || model.progress != nil {
            Section {
                if let progress = model.progress, model.sending { ProgressView(value: progress) }
                if !model.status.isEmpty { Text(model.status).font(.footnote) }
            }
        }
    }
}
