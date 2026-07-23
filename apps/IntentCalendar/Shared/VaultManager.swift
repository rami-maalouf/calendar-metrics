import Foundation
import SwiftUI
import os

class VaultManager: ObservableObject {
    private let defaults: UserDefaults

    @Published var vaultURL: URL?
    @Published var isVaultConfigured: Bool = false
    @Published var showOnboarding: Bool = false
    @Published var error: String?
    @Published var inferredTemplate: InferredTemplate?

    private static let templateKey = "inferredTemplate"

    init(defaults: UserDefaults = UserDefaults(suiteName: AppConstants.appGroupID) ?? .standard) {
        self.defaults = defaults
        restoreAccess()
        restoreTemplate()
    }

    func restoreAccess() {
        guard let bookmark = defaults.data(forKey: AppConstants.UserDefaultsKey.vaultBookmark) else {
            Logger.vault.debug("No Daily Notes bookmark found.")
            return
        }

        var isStale = false
        do {
            #if os(macOS)
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            if isStale {
                Logger.vault.warning("Daily Notes bookmark is stale.")
            }

            #if os(macOS)
            if url.startAccessingSecurityScopedResource() {
                vaultURL = url
                isVaultConfigured = true
                Logger.vault.info("Restored Daily Notes access: \(url.path)")
            } else {
                error = "Could not access the Daily Notes folder. Please select it again."
                defaults.removeObject(forKey: AppConstants.UserDefaultsKey.vaultBookmark)
                isVaultConfigured = false
            }
            #else
            vaultURL = url
            isVaultConfigured = true
            Logger.vault.info("Restored Daily Notes access: \(url.path)")
            #endif
        } catch {
            Logger.vault.error("Error restoring Daily Notes access: \(error.localizedDescription)")
            self.error = "Error restoring access: \(error.localizedDescription)"
            defaults.removeObject(forKey: AppConstants.UserDefaultsKey.vaultBookmark)
            isVaultConfigured = false
        }
    }

    func setVaultFolder(_ url: URL) {
        do {
            guard url.startAccessingSecurityScopedResource() else {
                error = "Failed to access the selected Daily Notes folder."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            #if os(macOS)
            let bookmark = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif

            defaults.set(bookmark, forKey: AppConstants.UserDefaultsKey.vaultBookmark)
            restoreAccess()
        } catch {
            self.error = "Failed to save Daily Notes folder permission: \(error.localizedDescription)"
        }
    }

    func reset() {
        defaults.removeObject(forKey: AppConstants.UserDefaultsKey.vaultBookmark)
        vaultURL = nil
        isVaultConfigured = false
        error = nil
    }

    func performInVault<T>(_ block: (URL) throws -> T) throws -> T {
        guard let url = vaultURL else {
            throw VaultError.notConfigured
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try block(url)
    }

    func fetchDailyNotesContext(for date: Date, count: Int) throws -> [DailyNoteContext] {
        try performInVault { vaultURL in
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: nil)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let calendar = Calendar.current
            let requestedDay = calendar.startOfDay(for: date.journalDate)

            let datedFiles = contents.compactMap { fileURL -> (Date, URL)? in
                guard fileURL.pathExtension.lowercased() == "md" else {
                    return nil
                }
                let stem = fileURL.deletingPathExtension().lastPathComponent
                guard let parsed = formatter.date(from: stem) else {
                    return nil
                }
                return (parsed, fileURL)
            }
            .sorted { $0.0 > $1.0 }

            let selected = datedFiles.first(where: { calendar.isDate($0.0, inSameDayAs: requestedDay) })
            let previous = datedFiles
                .filter { $0.0 < requestedDay }
                .prefix(max(0, count))

            return ([selected].compactMap { $0 } + previous)
                .sorted { $0.0 > $1.0 }
                .compactMap { fileDate, url in
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                        return nil
                    }
                    return DailyNoteContext(url: url, date: fileDate, content: content)
                }
        }
    }

    func fetchRecentDailyNotes(count: Int = 5) throws -> [DailyNoteSample] {
        try fetchDailyNotesContext(for: Date().journalDate, count: count).map {
            DailyNoteSample(date: $0.date, content: $0.content)
        }
    }

    func saveTemplate(_ template: InferredTemplate) {
        do {
            let data = try JSONEncoder().encode(template)
            defaults.set(data, forKey: Self.templateKey)
            inferredTemplate = template
        } catch {
            Logger.vault.error("Failed to save compatibility template cache: \(error.localizedDescription)")
        }
    }

    func clearTemplate() {
        defaults.removeObject(forKey: Self.templateKey)
        inferredTemplate = nil
    }

    private func restoreTemplate() {
        guard let data = defaults.data(forKey: Self.templateKey) else {
            return
        }

        do {
            inferredTemplate = try JSONDecoder().decode(InferredTemplate.self, from: data)
        } catch {
            defaults.removeObject(forKey: Self.templateKey)
        }
    }
}

enum VaultError: Error {
    case notConfigured
    case accessDenied
}
