import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var thermalDisabled = false
    @State private var otaDisabled = false
    @State private var systemCacheUsage = SystemCacheUsage.empty
    @State private var systemControlAlert: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AppLogo()

                        VStack(alignment: .leading, spacing: 3) {
                            Text("3105").font(.headline)
                            Text(language.text("common.version", appVersion))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(language.text("settings.language")) {
                    Picker(language.text("settings.language"), selection: $languageCode) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                }

                Section {
                    Toggle("Disable thermalmonitord", isOn: $thermalDisabled)
                        .onChange(of: thermalDisabled) { value in
                            applyThermal(value)
                        }

                    Toggle("Disable OTA", isOn: $otaDisabled)
                        .onChange(of: otaDisabled) { value in
                            applyOTA(value)
                        }

                    LabeledContent("Global cache", value: ByteCountFormatter.string(
                        fromByteCount: systemCacheUsage.bytes,
                        countStyle: .file
                    ))

                    Button {
                        cleanSystemCache()
                    } label: {
                        Label(
                            "Clean safe system caches",
                            systemImage: "trash"
                        )
                    }
                    .disabled(systemCacheUsage.bytes == 0)
                } header: {
                    Text("System Controls")
                } footer: {
                    Text("Thermal/OTA changes are stored in launchd disabled.plist and require a reboot. Cache cleanup only touches the allowlisted cache/log folders.")
                }

                Section {
                    HStack {
                        Text(language.text("settings.current_version"))
                        Spacer()
                        Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                        .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    }
                    LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                    LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                    LabeledContent("iOS 26", value: ExploitSupportPolicy.verifiedIOS26Range)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iOS 27.0")
                            .font(.body)
                        ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { version in
                            Text(versionLabel(version))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text(language.text("settings.verified_versions"))
                } footer: {
                    Text(language.text("settings.supported_versions_footer"))
                }

                Section(language.text("settings.social_media")) {
                    creditsRow(
                        name: "GitHub",
                        role: language.text("social.github_role"),
                        url: "https://github.com/YangJiiii/3105"
                    )
                    creditsRow(
                        name: "Cá»ng Äá»ng IOSVN",
                        role: language.text("social.iosvn_role"),
                        url: "https://t.me/ioscrackvn"
                    )
                }

                Section(language.text("settings.credits")) {
                    creditsRow(
                        name: "YangJiii",
                        role: language.text("credit.yangjiii"),
                        url: "https://x.com/duongduong0908"
                    )
                    creditsRow(
                        name: "0xjohnnydev",
                        role: language.text("credit.filzaslop"),
                        url: "https://github.com/0xjohnnydev/FilzaSlop"
                    )
                    creditsRow(
                        name: "LeminLimez",
                        role: language.text("credit.pocket_poster"),
                        url: "https://github.com/leminlimez/Pocket-Poster"
                    )
                    creditsRow(
                        name: "CrazyMind90",
                        role: language.text("credit.sandbox_escape"),
                        url: "https://github.com/CrazyMind90"
                    )
                    creditsRow(
                        name: "forcequitOS",
                        role: language.text("credit.forcequit"),
                        url: "https://github.com/forcequitOS"
                    )
                }
            }
            .tint(AppTheme.accent)
            .onAppear {
                refreshSystemControls()
            }
            .alert("System Controls", isPresented: Binding(
                get: { systemControlAlert != nil },
                set: { if !$0 { systemControlAlert = nil } }
            )) {
                Button("OK") { systemControlAlert = nil }
            } message: {
                Text(systemControlAlert ?? "")
            }
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private func versionLabel(
        _ version: (beta: Int, publicBeta: Int?, build: String)
    ) -> String {
        if let publicBeta = version.publicBeta {
            return language.text(
                "settings.developer_public_beta_build",
                Int64(version.beta),
                Int64(publicBeta),
                version.build
            )
        }
        return language.text(
            "settings.developer_beta_build",
            Int64(version.beta),
            version.build
        )
    }

    private func refreshSystemControls() {
        thermalDisabled = SystemControlService.thermalDisabled()
        otaDisabled = SystemControlService.otaDisabled()
        DispatchQueue.global(qos: .utility).async {
            let usage = SystemCacheService.scan()
            DispatchQueue.main.async {
                systemCacheUsage = usage
            }
        }
    }

    private func applyThermal(_ disabled: Bool) {
        guard KernelExploit.hasSandboxAccess() || SystemControlService.disabledPlistURL.map({
            FileManager.default.isReadableFile(atPath: $0.path)
        }) == true else {
            thermalDisabled = !disabled
            systemControlAlert = SystemControlError.accessDenied.localizedDescription
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SystemControlService.setThermalDisabled(disabled)
            } catch {
                DispatchQueue.main.async {
                    thermalDisabled = !disabled
                    systemControlAlert = error.localizedDescription
                }
            }
        }
    }

    private func applyOTA(_ disabled: Bool) {
        guard KernelExploit.hasSandboxAccess() || SystemControlService.disabledPlistURL.map({
            FileManager.default.isReadableFile(atPath: $0.path)
        }) == true else {
            otaDisabled = !disabled
            systemControlAlert = SystemControlError.accessDenied.localizedDescription
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SystemControlService.setOTADisabled(disabled)
            } catch {
                DispatchQueue.main.async {
                    otaDisabled = !disabled
                    systemControlAlert = error.localizedDescription
                }
            }
        }
    }

    private func cleanSystemCache() {
        DispatchQueue.global(qos: .utility).async {
            let result = SystemCacheService.clean()
            let message = "Freed \(ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)). Removed \(result.removedItemCount) files."
            let usage = result.after
            DispatchQueue.main.async {
                systemCacheUsage = usage
                systemControlAlert = message
            }
        }
    }

    @ViewBuilder
    private func creditsRow(name: String, role: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 28, height: 28)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(language.text("accessibility.open_profile", name))
        }
    }
}
