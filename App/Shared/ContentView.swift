import MeshCore
import SwiftUI

struct ContentView: View {
    @Environment(ChatModel.self) private var model
    @State private var showingProfile = false

    var body: some View {
        NavigationSplitView {
            Sidebar(showingProfile: $showingProfile)
        } detail: {
            if let selection = model.selection {
                ConversationView(conversation: selection)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
        .onAppear { model.start() }
    }
}

private struct Sidebar: View {
    @Environment(ChatModel.self) private var model
    @Binding var showingProfile: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                ConversationRow(
                    title: "Everyone",
                    subtitle: "Public channel, signed but not encrypted",
                    isUnread: model.unread.contains(.everyone),
                    isOnline: nil
                )
                .tag(Conversation.everyone)
            }
            Section("People") {
                if model.directConversations.isEmpty {
                    Text("No one nearby yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.directConversations, id: \.self) { key in
                    let peer = model.peer(for: key)
                    ConversationRow(
                        title: model.displayName(for: key),
                        subtitle: peer.map { "Seen \($0.lastSeen.formatted(.relative(presentation: .named)))" } ?? "Waiting for their announce",
                        isUnread: model.unread.contains(.direct(key)),
                        isOnline: peer.map { Date().timeIntervalSince($0.lastSeen) < 15 * 60 }
                    )
                    .tag(Conversation.direct(key))
                }
            }
        }
        .navigationTitle("MeshChat")
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingProfile = true
                } label: {
                    Label("Profile", systemImage: "person.crop.circle")
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let title: String
    let subtitle: String
    let isUnread: Bool
    let isOnline: Bool?

    var body: some View {
        HStack {
            if let isOnline {
                Circle()
                    .fill(isOnline ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(isUnread ? .bold : .regular)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isUnread {
                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
            }
        }
    }
}

private struct StatusBar: View {
    @Environment(ChatModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.status == .ready ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.status.label)
            Spacer()
            Text(model.linkCount == 1 ? "1 link" : "\(model.linkCount) links")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ConversationView: View {
    @Environment(ChatModel.self) private var model
    let conversation: Conversation
    @State private var draft = ""

    var body: some View {
        let lines = model.lines[conversation] ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if lines.isEmpty {
                        Text(emptyText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                    ForEach(lines) { line in
                        MessageBubble(line: line).id(line.id)
                    }
                }
                .padding()
            }
            .onChange(of: lines.count) {
                if let last = lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(model.title(for: conversation))
        .alert(
            "Couldn't send",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.lastError ?? "") }
        )
    }

    private var emptyText: String {
        switch conversation {
        case .everyone:
            return "Messages here reach everyone within up to 7 hops.\nEvery phone in between helps carry them."
        case .direct:
            return "Direct messages are end-to-end encrypted.\nPhones that relay them can't read them."
        }
    }

    private var canSend: Bool {
        model.canSend(in: conversation) && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        guard canSend else { return }
        model.send(draft, in: conversation)
        draft = ""
    }
}

private struct MessageBubble: View {
    let line: ChatLine

    var body: some View {
        VStack(alignment: line.isMine ? .trailing : .leading, spacing: 3) {
            Text(line.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(line.isMine ? Color.accentColor : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 14))
                .foregroundStyle(line.isMine ? Color.white : Color.primary)
                .textSelection(.enabled)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: line.isMine ? .trailing : .leading)
    }

    private var caption: String {
        let time = line.date.formatted(date: .omitted, time: .shortened)
        guard let relays = line.relays else { return time }
        let route = switch relays {
        case 0: "direct"
        case 1: "via 1 relay"
        default: "via \(relays) relays"
        }
        return "\(line.author) · \(time) · \(route)"
    }
}

private struct ProfileView: View {
    @Environment(ChatModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Nickname") {
                    TextField("Nickname", text: $name)
                }
                Section {
                    LabeledContent("You appear as", value: model.myName)
                    Text(model.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Your identity is a key pair made on this device. Nicknames aren't unique, so compare fingerprints in person before trusting someone.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.rename(to: name)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
        .onAppear { name = model.nickname }
    }
}
