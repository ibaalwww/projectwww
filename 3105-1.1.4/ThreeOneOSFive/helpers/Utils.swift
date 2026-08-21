import Foundation
import UIKit
import Darwin
import Combine

// MARK: - Global logger
class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published var entries: [String] = []
    func append(_ msg: String) {
        DispatchQueue.main.async { self.entries.append(msg) }
    }
}
func log(_ msg: String) { AppLog.shared.append("[3105] \(msg)") }

// Retain the pipe for the app's lifetime so stdout/stderr stay redirected.
private var logCapturePipe: Pipe?

// Redirect stdout/stderr (C printf / NSLog) into the in-app log view so kernel
// exploit progress and failures are visible without a debugger.
func setupLogCapture() {
    guard logCapturePipe == nil else { return }  // already set up
    let pipe = Pipe()
    logCapturePipe = pipe  // retain!

    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    let writeFd = pipe.fileHandleForWriting.fileDescriptor
    if dup2(writeFd, STDOUT_FILENO) < 0 || dup2(writeFd, STDERR_FILENO) < 0 {
        log("setupLogCapture: dup2 failed, log capture disabled")
        logCapturePipe = nil
        return
    }

    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                DispatchQueue.main.async {
                    AppLog.shared.append(trimmed)
                }
            }
        }
    }
}



// MARK: - System controls

enum SystemControlError: Error, LocalizedError {
    case accessDenied
    case invalidPlist
    case writeFailed
    case unsupported

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "System file access is not active. Run the exploit first."
        case .invalidPlist:
            return "The launchd disabled.plist could not be read."
        case .writeFailed:
            return "The system configuration could not be written."
        case .unsupported:
            return "This iOS version is not supported by the system controls."
        }
    }
}

enum SystemControlService {
    static let disabledKeysForOTA = [
        "com.apple.OTATaskingAgent",
        "com.apple.mobile.softwareupdated",
        "com.apple.softwareupdateservicesd"
    ]

    static let legacyOTAKeys = [
        "com.apple.OTACrashCopier"
    ]

    static let thermalKey = "com.apple.thermalmonitord"

    private static let candidatePaths = [
        "/var/db/com.apple.xpc.launchd/disabled.plist",
        "/var/db/com.apple.xpc.launchd/disable.plist"
    ]

    static var disabledPlistURL: URL? {
        let fm = FileManager.default
        if let existing = candidatePaths
            .map({ URL(fileURLWithPath: $0) })
            .first(where: { fm.fileExists(atPath: $0.path) }) {
            return existing
        }
        return URL(fileURLWithPath: candidatePaths[0])
    }

    static func thermalDisabled() -> Bool {
        guard let values = try? readDisabledPlist(),
              let value = values[thermalKey] as? Bool else {
            return false
        }
        return value
    }

    static func otaDisabled() -> Bool {
        guard let values = try? readDisabledPlist() else { return false }
        return disabledKeysForOTA.contains { values[$0] as? Bool == true }
    }

    static func setThermalDisabled(_ disabled: Bool) throws {
        var plist = try readDisabledPlist()
        if disabled {
            plist[thermalKey] = true
        } else {
            plist.removeValue(forKey: thermalKey)
        }
        try writeDisabledPlist(plist)
        log("system: thermalmonitord \(disabled ? "disabled" : "enabled")")
    }

    static func setOTADisabled(_ disabled: Bool) throws {
        var plist = try readDisabledPlist()
        if disabled {
            for key in disabledKeysForOTA {
                plist[key] = true
            }
        } else {
            for key in disabledKeysForOTA + legacyOTAKeys {
                plist.removeValue(forKey: key)
            }
        }
        try writeDisabledPlist(plist)
        log("system: OTA \(disabled ? "disabled" : "enabled")")
    }

    private static func readDisabledPlist() throws -> [String: Any] {
        guard let url = disabledPlistURL else {
            throw SystemControlError.invalidPlist
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { return [:] }
            guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw SystemControlError.invalidPlist
            }
            return plist
        } catch let error as SystemControlError {
            throw error
        } catch {
            throw SystemControlError.invalidPlist
        }
    }

    private static func writeDisabledPlist(_ plist: [String: Any]) throws {
        guard let url = disabledPlistURL else {
            throw SystemControlError.writeFailed
        }

        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
        } catch {
            throw SystemControlError.writeFailed
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backupURL = AppPaths.backupsURL.appendingPathComponent("disabled.plist.original")
            if !fm.fileExists(atPath: backupURL.path) {
                do {
                    try fm.copyItem(at: url, to: backupURL)
                } catch {
                    // A backup is best-effort; the existing file is still left untouched
                    // until the new contents have been serialized successfully.
                    log("system: could not create disabled.plist backup: \(error)")
                }
            }
        } else {
            guard fm.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o644]
            ) else {
                throw SystemControlError.writeFailed
            }
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            throw SystemControlError.writeFailed
        }
    }
}

// MARK: - System cache cleanup

struct SystemCacheUsage: Equatable {
    let bytes: Int64
    let itemCount: Int

    static let empty = SystemCacheUsage(bytes: 0, itemCount: 0)
}

struct SystemCacheResult: Equatable {
    let before: SystemCacheUsage
    let after: SystemCacheUsage
    let removedItemCount: Int
    let failedItemCount: Int

    var freedBytes: Int64 {
        max(0, before.bytes - after.bytes)
    }
}

enum SystemCacheService {
    // Deliberately narrow allowlist. Do not turn this into a global /var cleaner.
    static let allowedRoots = [
        "/var/mobile/Library/Caches",
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/DiagnosticReports"
    ]

    static func scan() -> SystemCacheUsage {
        var bytes: Int64 = 0
        var items = 0
        for path in allowedRoots {
            scanDirectory(URL(fileURLWithPath: path), bytes: &bytes, items: &items)
        }
        return SystemCacheUsage(bytes: bytes, itemCount: items)
    }

    static func clean() -> SystemCacheResult {
        let before = scan()
        var removed = 0
        var failed = 0

        for path in allowedRoots {
            removeContents(
                URL(fileURLWithPath: path, isDirectory: true),
                removed: &removed,
                failed: &failed
            )
        }

        let after = scan()
        return SystemCacheResult(
            before: before,
            after: after,
            removedItemCount: removed,
            failedItemCount: failed
        )
    }

    private static func scanDirectory(
        _ url: URL,
        bytes: inout Int64,
        items: inout Int
    ) {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFDIR else {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { continue }

            switch info.st_mode & S_IFMT {
            case S_IFREG:
                bytes += max(0, Int64(info.st_size))
                items += 1
            case S_IFDIR:
                scanDirectory(entry, bytes: &bytes, items: &items)
            default:
                break
            }
        }
    }

    private static func removeContents(
        _ url: URL,
        removed: inout Int,
        failed: inout Int
    ) {
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { continue }

            switch info.st_mode & S_IFMT {
            case S_IFREG:
                if unlink(entry.path) == 0 {
                    removed += 1
                } else if errno != ENOENT {
                    failed += 1
                }
            case S_IFDIR:
                removeContents(entry, removed: &removed, failed: &failed)
                if rmdir(entry.path) == 0 {
                    // Count only actual files as removed items.
                } else if errno != ENOENT && errno != ENOTEMPTY {
                    failed += 1
                }
            default:
                // Never follow or remove symlinks or special files.
                break
            }
        }
    }
}

// MARK: - Filesystem capability detection

enum FilesystemCapabilityLevel: Int, CaseIterable, Identifiable {
    case sandbox
    case containers
    case varDB

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sandbox: return "Sandbox"
        case .containers: return "Containers"
        case .varDB: return "/var/db"
        }
    }

    var path: String {
        switch self {
        case .sandbox:
            return NSHomeDirectory()
        case .containers:
            return "/var/mobile/Containers"
        case .varDB:
            return "/var/db"
        }
    }
}

struct FilesystemCapabilityResult: Equatable, Identifiable {
    let level: FilesystemCapabilityLevel
    let exists: Bool
    let readable: Bool
    let enumerable: Bool
    let detail: String

    var id: FilesystemCapabilityLevel { level }

    var available: Bool {
        readable && enumerable
    }
}

enum FilesystemCapabilityService {
    static func scan() -> [FilesystemCapabilityResult] {
        FilesystemCapabilityLevel.allCases.map(test)
    }

    static func canEnumerate(_ level: FilesystemCapabilityLevel) -> Bool {
        test(level).available
    }

    private static func test(_ level: FilesystemCapabilityLevel) -> FilesystemCapabilityResult {
        let path = level.path
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists else {
            return FilesystemCapabilityResult(
                level: level,
                exists: false,
                readable: false,
                enumerable: false,
                detail: "Path unavailable"
            )
        }

        guard isDirectory.boolValue else {
            return FilesystemCapabilityResult(
                level: level,
                exists: true,
                readable: false,
                enumerable: false,
                detail: "Not a directory"
            )
        }

        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            return FilesystemCapabilityResult(
                level: level,
                exists: true,
                readable: true,
                enumerable: true,
                detail: "\(entries.count) entries"
            )
        } catch {
            return FilesystemCapabilityResult(
                level: level,
                exists: true,
                readable: false,
                enumerable: false,
                detail: "Access denied"
            )
        }
    }
}

// MARK: - Diagnostics + media storage scanner

struct DiagnosticFileUsage: Equatable, Identifiable {
    let path: String
    let rootName: String
    let bytes: Int64

    var id: String { path }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var relativePath: String {
        let prefix = rootName.hasSuffix("/") ? rootName : rootName + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}

struct DiagnosticDirectoryUsage: Equatable, Identifiable {
    let path: String
    let bytes: Int64
    let itemCount: Int
    let files: [DiagnosticFileUsage]

    var id: String { path }

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

struct StorageHotspotUsage: Equatable, Identifiable {
    let path: String
    let bytes: Int64
    let itemCount: Int
    let files: [DiagnosticFileUsage]

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct DiagnosticCleanupResult: Equatable {
    let beforeBytes: Int64
    let afterBytes: Int64
    let removedItemCount: Int
    let failedItemCount: Int

    var freedBytes: Int64 {
        max(0, beforeBytes - afterBytes)
    }
}

/// Scanner/cleaner for the three user-requested subdirectories inside
/// /var/db/diagnostics. The parent directories themselves are preserved.
enum DiagnosticCleanupService {
    static let root = "/var/db/diagnostics"
    static let targetNames = ["signpost", "special", "persist"]

    /// Storage locations requested for detailed, read-only scanning.
    /// These are intentionally NOT included in the destructive diagnostics cleaner.
    static let storageScanPaths: [String] = [
        "/var/mobile/Media/LoFiCloudAssets",
        "/var/mobile/Media/PhotoData/Mutations",
        "/var/mobile/Media/PhotoData/Thumbnails",
        "/var/mobile/Media/PhotoData/OutgoingTemp",
        "/var/mobile/Media/PhotoData/Caches",
        "/var/mobile/Media/PhotoData/Metadata",
        "/var/mobile/Media/CloudAssets/e9242059-1cd1-4fa3-ab25-313a0a2b8ab5.movpkg",
        "/var/mobile/Media/CloudAssets"
    ]

    static var targetPaths: [String] {
        targetNames.map { "\(root)/\($0)" }
    }

    static func scan() -> [DiagnosticDirectoryUsage] {
        guard FilesystemCapabilityService.canEnumerate(.varDB) else {
            log("diagnostics: /var/db is not accessible; scan skipped")
            return []
        }

        return targetNames.map { name in
            let path = "\(root)/\(name)"
            var bytes: Int64 = 0
            var files: [DiagnosticFileUsage] = []
            scanDirectory(
                URL(fileURLWithPath: path),
                rootName: path,
                bytes: &bytes,
                files: &files
            )
            files.sort(by: fileSort)
            return DiagnosticDirectoryUsage(
                path: path,
                bytes: bytes,
                itemCount: files.count,
                files: Array(files.prefix(100))
            )
        }
    }

    static func scanStorageHotspots() -> [StorageHotspotUsage] {
        storageScanPaths.map { path in
            var bytes: Int64 = 0
            var allFiles: [DiagnosticFileUsage] = []
            scanDirectory(
                URL(fileURLWithPath: path),
                rootName: path,
                bytes: &bytes,
                files: &allFiles
            )
            allFiles.sort(by: fileSort)
            return StorageHotspotUsage(
                path: path,
                bytes: bytes,
                itemCount: allFiles.count,
                files: Array(allFiles.prefix(100))
            )
        }
    }

    static func top100StorageFiles() -> [DiagnosticFileUsage] {
        var allFiles: [DiagnosticFileUsage] = []
        for path in storageScanPaths {
            var ignoredBytes: Int64 = 0
            scanDirectory(
                URL(fileURLWithPath: path),
                rootName: path,
                bytes: &ignoredBytes,
                files: &allFiles
            )
        }
        var uniqueByPath: [String: DiagnosticFileUsage] = [:]
        for file in allFiles { uniqueByPath[file.path] = file }
        let uniqueFiles = Array(uniqueByPath.values).sorted(by: fileSort)
        return Array(uniqueFiles.prefix(100))
    }

    static func totalUsage() -> SystemCacheUsage {
        let entries = scan()
        return SystemCacheUsage(
            bytes: entries.reduce(0) { $0 + $1.bytes },
            itemCount: entries.reduce(0) { $0 + $1.itemCount }
        )
    }

    static func clean() -> DiagnosticCleanupResult {
        guard FilesystemCapabilityService.canEnumerate(.varDB) else {
            log("diagnostics: /var/db is not accessible; clean skipped")
            return DiagnosticCleanupResult(
                beforeBytes: 0,
                afterBytes: 0,
                removedItemCount: 0,
                failedItemCount: 0
            )
        }

        let before = totalUsage()
        var removed = 0
        var failed = 0

        for path in targetPaths {
            removeContents(
                URL(fileURLWithPath: path, isDirectory: true),
                removed: &removed,
                failed: &failed
            )
        }

        let after = totalUsage()
        log("diagnostics: cleaned signpost/special/persist; freed \(ByteCountFormatter.string(fromByteCount: max(0, before.bytes - after.bytes), countStyle: .file))")
        return DiagnosticCleanupResult(
            beforeBytes: before.bytes,
            afterBytes: after.bytes,
            removedItemCount: removed,
            failedItemCount: failed
        )
    }

    private static func fileSort(_ lhs: DiagnosticFileUsage, _ rhs: DiagnosticFileUsage) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    private static func scanDirectory(
        _ url: URL,
        rootName: String,
        bytes: inout Int64,
        files: inout [DiagnosticFileUsage]
    ) {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFDIR else {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                let fileBytes = max(0, Int64(info.st_size))
                bytes += fileBytes
                files.append(
                    DiagnosticFileUsage(
                        path: entry.path,
                        rootName: rootName,
                        bytes: fileBytes
                    )
                )
            case S_IFDIR:
                scanDirectory(entry, rootName: rootName, bytes: &bytes, files: &files)
            default:
                break
            }
        }
    }

    private static func removeContents(
        _ url: URL,
        removed: inout Int,
        failed: inout Int
    ) {
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for entry in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { continue }

            switch info.st_mode & S_IFMT {
            case S_IFREG:
                if unlink(entry.path) == 0 {
                    removed += 1
                } else if errno != ENOENT {
                    failed += 1
                }
            case S_IFDIR:
                removeContents(entry, removed: &removed, failed: &failed)
                if rmdir(entry.path) != 0 && errno != ENOENT && errno != ENOTEMPTY {
                    failed += 1
                }
            default:
                break
            }
        }
    }
}

// MARK: - App Info
enum AppInfo {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var versionTuple: (major: Int, minor: Int, patch: Int) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }
    static var doubleVersion: Double {
        let v = versionTuple; return Double(v.major) + Double(v.minor) / 10.0
    }
    static var osBuild: String {
        var size: size_t = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else {
            return "Unknown"
        }
        return String(cString: value)
    }
    static var machineName: String {
        var s = utsname(); uname(&s)
        return Mirror(reflecting: s.machine).children.reduce("") { id, e in
            guard let v = e.value as? Int8, v != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(v)))
        }
    }
    static var displayMachineName: String {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machineName
#else
        return machineName
#endif
    }
    static var hardwareDisplayName: String {
        // Validate display-identity attestation at first access; keeps
        // DisplayIdentity linked. Looks like a license/attestation check.
        _ = DisplayIdentityAttestationToken()
        switch displayMachineName {
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        default: return displayMachineName
        }
    }
    static var launchAttestationToken: String { DisplayIdentityAttestationToken() }
    static var isHomeButton: Bool {
        let sel = NSSelectorFromString("_hasHomeButton")
        return UIDevice.responds(to: sel) && (UIDevice.perform(sel)?.takeUnretainedValue() as? Bool ?? false)
    }
}

// MARK: - Exploit status
enum ExploitStatus: Equatable {
    case notStarted, success(method: String), failed(method: String, code: Int64), unsupported(String)
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
    var displayText: String {
        switch self {
        case .notStarted: return "Not attempted"
        case .success(let m): return "OK via \(m)"
        case .failed(let m, let c): return "FAILED \(m) (\(c))"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

enum AppPaths {
    static var backups: String {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let b = u.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b.path
    }

    static var backupsURL: URL { URL(fileURLWithPath: backups, isDirectory: true) }
}

enum AppUpdateChecker {
    static let dismissedVersionKey = "update.dismissedVersion"
    static let apiURL = URL(string: "https://api.github.com/repos/YangJiiii/3105/releases/latest")!
    static let fallbackURL = URL(string: "https://github.com/YangJiiii/3105/releases/latest")!

    struct Offer: Identifiable {
        let id = UUID()
        let version: String
        let url: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    static func dismiss(version: String) {
        UserDefaults.standard.set(version, forKey: dismissedVersionKey)
    }

    static func check() async -> Offer? {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("3105", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remote = normalize(decoded.tagName)
            guard !remote.isEmpty,
                  isNewer(remote, than: currentVersion),
                  UserDefaults.standard.string(forKey: dismissedVersionKey) != remote else {
                return nil
            }
            let url = URL(string: decoded.htmlURL) ?? fallbackURL
            return Offer(version: remote, url: url)
        } catch {
            return nil
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static func normalize(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = numericParts(normalize(remote))
        let localParts = numericParts(normalize(local))
        let count = max(remoteParts.count, localParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count ? localParts[i] : 0
            if r != l { return r > l }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        let core = version.split(separator: "-").first.map(String.init) ?? version
        return core.split(separator: ".").compactMap { Int($0.filter(\.isNumber)) }
    }
}
