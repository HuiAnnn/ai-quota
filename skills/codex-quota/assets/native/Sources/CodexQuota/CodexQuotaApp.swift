import AppKit
import Foundation
import QuotaCore
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--diagnose-all") {
            await QuotaDiagnostics.printAll()
            return
        }
        if args.contains("--diagnose-announcements") {
            do {
                let items = try await AnnouncementClient().fetch()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(items), as: UTF8.self))
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if args.contains("--diagnose") || args.contains("--render-preview") {
            await runDiagnostic(args: args)
            return
        }
        QuotaMenuApp.main()
    }

    @MainActor
    private static func runDiagnostic(args: [String]) async {
        guard let executable = CodexExecutableLocator.locate() else {
            fputs("未找到 Codex 可执行文件\n", stderr)
            exit(1)
        }
        let client = CodexClient(executableURL: executable)
        do {
            let snapshot = try await client.fetchSnapshot()
            await client.disconnect()
            if let index = args.firstIndex(of: "--render-preview"), index + 1 < args.count {
                _ = NSApplication.shared
                NSApplication.shared.setActivationPolicy(.accessory)
                let store = QuotaStore(snapshot: snapshot, updatedAt: Date(), start: false)
                let announcements: AnnouncementStore
                if let fixtureIndex = args.firstIndex(of: "--preview-announcements"), fixtureIndex + 1 < args.count {
                    let items = try ResetAnnouncement.decodeFeed(Data(contentsOf: URL(fileURLWithPath: args[fixtureIndex + 1])))
                    announcements = AnnouncementStore(cacheURL: nil, start: false, loader: { items })
                } else {
                    announcements = AnnouncementStore(start: false)
                }
                await announcements.refresh()
                let dashboard = await QuotaDiagnostics.previewStore(codex: store)
                if let detailIndex = args.firstIndex(of: "--preview-provider"), detailIndex + 1 < args.count {
                    dashboard.selectDetail(args[detailIndex + 1])
                }
                let root = AIQuotaPanel(store: dashboard, codex: store, announcements: announcements, refreshOnAppear: false)
                let view = NSHostingView(rootView: root)
                view.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
                view.frame = NSRect(x: 0, y: 0, width: 420, height: 800)
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                view.frame = NSRect(x: 0, y: 0, width: 420, height: size.height)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw NSError(domain: "CodexQuota", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法渲染预览"])
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "CodexQuota", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法导出预览"])
                }
                try png.write(to: URL(fileURLWithPath: args[index + 1]))
                print("已渲染实时额度预览：\(args[index + 1])")
            } else {
                // Allowlisted fields only: never print account IDs, email or auth data.
                var output: [String: Any] = [
                    "buckets": snapshot.orderedBuckets.map { entry -> [String: Any] in
                        ["name": entry.displayName,
                         "windows": [entry.bucket.primary, entry.bucket.secondary].compactMap { window -> [String: Any]? in
                             guard let window else { return nil }
                             return ["period": window.periodLabel,
                                     "remainingPercent": window.remainingPercent as Any? ?? NSNull(),
                                     "resetsAt": window.resetsAt as Any? ?? NSNull()]
                         }]
                    }
                ]
                if let credits = snapshot.rateLimitResetCredits {
                    output["availableResets"] = credits.displayCount as Any? ?? NSNull()
                    output["resetExpirations"] = credits.sortedCredits.map {
                        $0.expiresAt as Any? ?? NSNull()
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
        } catch {
            await client.disconnect()
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
struct QuotaMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AIQuotaStore.shared
    @StateObject private var codex = QuotaStore.shared

    var body: some Scene {
        MenuBarExtra {
            AIQuotaPanel(store: store, codex: codex)
        } label: {
            Text(store.menuTitle).monospacedDigit()
                .help("\(store.defaultDescriptor?.name ?? "Codex") 剩余额度：\(store.menuTitle)")
                .accessibilityLabel("\(store.defaultDescriptor?.name ?? "Codex") 剩余额度：\(store.menuTitle)")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        _ = AnnouncementStore.shared
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            AnnouncementStore.shared.shutdown()
            MuseWebSession.shared.shutdown()
            await AIQuotaStore.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
