import AppKit
import QuotaCore
import SwiftUI

struct AIQuotaPanel: View {
    @ObservedObject var store: AIQuotaStore
    @ObservedObject var codex: QuotaStore
    @ObservedObject var announcements: AnnouncementStore = .shared
    @ObservedObject var connections: ConnectionCoordinator = .shared
    var refreshOnAppear = true
    @State private var showingAddProvider = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: 0) {
                    overview
                    Divider()
                    if let descriptor = store.selectedDescriptor {
                        ProviderActionsBar(descriptor: descriptor, state: store.state(for: descriptor.id),
                                           isDefault: store.defaultProviderID == descriptor.id,
                                           isConnecting: connections.connectingIDs.contains(descriptor.id),
                                           setDefault: { store.setDefault(descriptor.id) },
                                           connect: { connect(descriptor, authorize: true) },
                                           refresh: { store.requestRefresh(descriptor.id) },
                                           open: { connections.openApplication(descriptor) },
                                           remove: { store.removeProvider(descriptor.id) })
                        Divider()
                    }
                    Form {
                        if store.selectedProviderID == "codex" {
                            CodexDetailSections(store: codex, announcements: announcements, now: timeline.date)
                        } else if let descriptor = store.selectedDescriptor {
                            ProviderDetailSection(descriptor: descriptor, state: store.state(for: descriptor.id), now: timeline.date,
                                                  isConnecting: connections.connectingIDs.contains(descriptor.id),
                                                  connect: { connect(descriptor) }, open: { connections.openApplication(descriptor) })
                        }
                    }
                    .formStyle(.grouped).frame(height: 285)
                    .id(store.selectedProviderID)
                }
            }
            Divider()
            footer
        }
        .frame(width: 420).fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if refreshOnAppear {
                store.panelDidOpen()
                announcements.requestRefresh()
            }
        }
        .sheet(isPresented: $showingAddProvider) { AddProviderView { try store.importProvider(fileURL: $0) } }
        .alert(item: $codex.resetAlert) { alert in
            if alert.canRetry {
                return Alert(title: Text(alert.title), message: Text(alert.message),
                             primaryButton: .default(Text(codex.pendingResetActionTitle)) { codex.retryPendingReset() },
                             secondaryButton: .cancel(Text("稍后")))
            }
            return Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 额度").font(.headline)
                Text("菜单栏显示 \(store.defaultDescriptor?.name ?? "Codex") · 北京时间")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.requestRefresh()
                announcements.requestRefresh(force: true)
            } label: {
                HStack(spacing: 5) {
                    if isRefreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(isRefreshing ? "刷新中" : "刷新")
                }
            }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isRefreshing)
                .help("刷新所有已显示应用的额度")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var overview: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(store.enabledDescriptors) { descriptor in
                    ProviderOverviewItem(descriptor: descriptor, state: store.state(for: descriptor.id),
                                        selected: store.selectedProviderID == descriptor.id,
                                        isDefault: store.defaultProviderID == descriptor.id,
                                        select: { store.selectDetail(descriptor.id) },
                                        isConnecting: connections.connectingIDs.contains(descriptor.id))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minWidth: 420, alignment: .center)
        }
        // Additional providers stay reachable without making the popover taller.
        .frame(height: 136)
    }

    private var footer: some View {
        HStack {
            Button { showingAddProvider = true } label: { Label("添加应用", systemImage: "plus") }
                .buttonStyle(.borderless).controlSize(.small)
            Spacer()
            Menu {
                Menu("菜单栏默认额度") {
                    ForEach(store.enabledDescriptors) { descriptor in
                        Button {
                            store.setDefault(descriptor.id)
                        } label: {
                            if store.defaultProviderID == descriptor.id { Label(descriptor.name, systemImage: "checkmark") }
                            else { Text(descriptor.name) }
                        }
                    }
                }
                Menu("显示的应用") {
                    ForEach(store.descriptors) { descriptor in
                        Toggle(descriptor.name, isOn: Binding(
                            get: { store.enabledProviderIDs.contains(descriptor.id) },
                            set: { store.setEnabled(descriptor.id, enabled: $0) }
                        ))
                    }
                }
                Divider()
                Toggle("登录时启动", isOn: Binding(get: { codex.launchAtLogin }, set: { codex.setLaunchAtLogin($0) }))
                if codex.loginItemNeedsApproval { Text("请在系统设置中允许登录启动") }
                if let error = codex.settingsError { Text(error) }
                Divider()
                Button("退出 AI 额度") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Label("设置", systemImage: "gearshape") }
                .controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func connect(_ descriptor: ProviderDescriptor, authorize: Bool = false) {
        connections.connect(descriptor, reason: authorize ? nil : store.state(for: descriptor.id)?.error) {
            store.requestRefresh(descriptor.id)
        }
    }

    private var isRefreshing: Bool {
        announcements.isRefreshing || store.enabledDescriptors.contains { store.state(for: $0.id)?.isRefreshing == true }
    }
}
