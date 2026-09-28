// swift-tools-version: 6.0
// Tuist spike: the same packages cmux.xcodeproj references, declared for
// Tuist's XcodeProj integration (TUIST_CMUX_DEPS=external). Only this mode lets
// `tuist cache` build them as binaries.
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [:],
    baseSettings: .settings(configurations: [
        .debug(name: "Debug"),
        .release(name: "Release"),
    ])
)
#endif

let package = Package(
    name: "CmuxTuistDependencies",
    dependencies: [
        .package(path: "../Packages/macOS/CmuxCloud"),
        .package(path: "../Packages/macOS/CmuxCloudTui"),
        .package(path: "../Packages/macOS/CmuxSurfaceCatalogModel"),
        .package(path: "../Packages/macOS/CmuxCloudMachines"),
        .package(path: "../Packages/Shared/CmuxWorkspacePresence"),
        .package(path: "../vendor/bonsplit"),
        .package(path: "../vendor/WireGuardKit"),
        .package(path: "../Packages/Shared/CMUXAuthCore"),
        .package(path: "../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../Packages/Shared/CmuxAgentChat"),
        .package(path: "../Packages/macOS/CmuxExtensionKit"),
        .package(path: "../Packages/macOS/CmuxSidebarProviderKit"),
        .package(path: "../Examples/CmuxExtensionSidebarExamples"),
        .package(path: "../Packages/macOS/CMUXProjectModel"),
        .package(path: "../Packages/macOS/CMUXAgentLaunch"),
        .package(path: "../Packages/macOS/CmuxAgentJournal"),
        .package(path: "../Packages/macOS/CmuxAgentSessionStore"),
        .package(path: "../Packages/macOS/CMUXDebugLog"),
        .package(path: "../Packages/macOS/CmuxDiffComments"),
        .package(path: "../Packages/macOS/CmuxCanvas"),
        .package(path: "../Packages/macOS/CmuxCanvasUI"),
        .package(path: "../Packages/macOS/CmuxSwiftRender"),
        .package(path: "../Packages/macOS/CmuxSwiftRenderUI"),
        .package(path: "../Packages/macOS/CmuxSidebarInterpreterService"),
        .package(path: "../Packages/macOS/CmuxSimulator"),
        .package(path: "../Packages/macOS/CmuxSudoBroker"),
        .package(path: "../Packages/macOS/CmuxSudoBrokerUI"),
        .package(path: "../Packages/macOS/CmuxWindowing"),
        .package(path: "../Packages/macOS/CmuxCommandPalette"),
        .package(path: "../Packages/macOS/CmuxGit"),
        .package(path: "../Packages/macOS/CmuxSidebarGit"),
        .package(path: "../Packages/macOS/CmuxSidebar"),
        .package(path: "../Packages/macOS/CmuxBrowser"),
        .package(path: "../Packages/macOS/CmuxNotifications"),
        .package(path: "../Packages/macOS/CmuxPhonePush"),
        .package(path: "../Packages/macOS/CmuxComputerUse"),
        .package(path: "../Packages/macOS/CmuxPanes"),
        .package(path: "../Packages/macOS/CmuxWorkspaces"),
        .package(path: "../Packages/macOS/CmuxControlSocket"),
        .package(path: "../Packages/macOS/CmuxAppKitSupportUI"),
        .package(path: "../Packages/macOS/CmuxFeedback"),
        .package(path: "../Packages/macOS/CmuxTerminalCore"),
        .package(path: "../Packages/macOS/CmuxTerminalImport"),
        .package(path: "../Packages/macOS/CmuxTerminal"),
        .package(path: "../Packages/macOS/CmuxSettings"),
        .package(path: "../Packages/macOS/CmuxTestSupport"),
        .package(path: "../Packages/macOS/CmuxSettingsUI"),
        .package(path: "../Packages/macOS/CmuxHive"),
        .package(path: "../Packages/macOS/CmuxUpdater"),
        .package(path: "../Packages/macOS/CmuxUpdaterUI"),
        .package(path: "../Packages/macOS/CmuxFoundation"),
        .package(path: "../Packages/Shared/CmuxSyntaxHighlighting"),
        .package(path: "../Packages/macOS/CmuxFilePreviewCore"),
        .package(path: "../Packages/macOS/CmuxCloudBannerCore"),
        .package(path: "../Packages/macOS/CmuxCloudTunnelCore"),
        .package(path: "../Packages/Shared/CmuxSentryTelemetry"),
        .package(path: "../Packages/macOS/CmuxCore"),
        .package(path: "../Packages/macOS/CmuxRemoteDaemon"),
        .package(path: "../Packages/macOS/CmuxRemoteWorkspace"),
        .package(path: "../Packages/macOS/CmuxRemoteSession"),
        .package(path: "../vendor/stack-auth-swift-sdk-prerelease"),
        .package(path: "../Packages/Shared/CMUXMobileCore"),
        .package(path: "../Packages/Shared/CmuxSimulatorStreamKit"),
        .package(path: "../Packages/Shared/CmuxIrohTransport"),
        .package(path: "../Packages/Shared/CmuxIrxTransport"),
        .package(path: "../Packages/iOS/CmuxMobileRPC"),
        .package(path: "../Packages/iOS/CmuxMobileTransport"),
        .package(path: "../Packages/macOS/CmuxCloudImagePaste"),
        .package(path: "../Packages/macOS/CmuxMobileHost"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.3.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.41.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/manaflow-ai/iroh-ffi.git", exact: "1.2.0-cmux.1.ios17"),
    ]
)
