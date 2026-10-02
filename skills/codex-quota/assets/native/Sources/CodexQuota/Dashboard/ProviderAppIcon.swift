import AppKit
import QuotaCore
import SwiftUI

@MainActor
struct ProviderAppIcon: View {
    let descriptor: ProviderDescriptor

    var body: some View {
        Group {
            if let icon = ProviderAppIconResolver.shared.icon(for: descriptor.bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(descriptor.name)
        .help(descriptor.name)
    }
}

@MainActor
private final class ProviderAppIconResolver {
    static let shared = ProviderAppIconResolver()

    private struct Entry {
        let image: NSImage?
        let resolvedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let maximumEntries = 32
    private let refreshInterval: TimeInterval = 60

    func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        let now = Date()
        if let entry = cache[bundleIdentifier], now.timeIntervalSince(entry.resolvedAt) < refreshInterval {
            return entry.image
        }

        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        if cache[bundleIdentifier] == nil, cache.count >= maximumEntries,
           let oldest = cache.min(by: { $0.value.resolvedAt < $1.value.resolvedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[bundleIdentifier] = Entry(image: image, resolvedAt: now)
        return image
    }
}
