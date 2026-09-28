// Tuist spike: generates the cmux macOS app, its helpers and its test bundles.
// Everything here mirrors cmux.xcodeproj at the commit this spike branched from.
// Build settings are copied verbatim (defaultSettings: .none), so the generated
// project compiles with the same flags as the hand-maintained one.
//
// TUIST_CMUX_DEPS=spm (default): local and remote packages stay Swift packages,
// integrated by Xcode exactly as today.
// TUIST_CMUX_DEPS=external: packages come from Tuist/Package.swift through
// Tuist's XcodeProj integration, which `tuist cache` needs to cache binaries.
import ProjectDescription

let useExternalDependencies = Environment.cmuxDeps.getString(default: "spm") == "external"

let localPackagePaths: [String] = [
    "Packages/macOS/CmuxCloud",
    "Packages/macOS/CmuxCloudTui",
    "Packages/macOS/CmuxSurfaceCatalogModel",
    "Packages/macOS/CmuxCloudMachines",
    "Packages/Shared/CmuxWorkspacePresence",
    "vendor/bonsplit",
    "vendor/WireGuardKit",
    "Packages/Shared/CMUXAuthCore",
    "Packages/Shared/CmuxAuthRuntime",
    "Packages/Shared/CmuxAgentChat",
    "Packages/macOS/CmuxExtensionKit",
    "Packages/macOS/CmuxSidebarProviderKit",
    "Examples/CmuxExtensionSidebarExamples",
    "Packages/macOS/CMUXProjectModel",
    "Packages/macOS/CMUXAgentLaunch",
    "Packages/macOS/CmuxAgentJournal",
    "Packages/macOS/CmuxAgentSessionStore",
    "Packages/macOS/CMUXDebugLog",
    "Packages/macOS/CmuxDiffComments",
    "Packages/macOS/CmuxCanvas",
    "Packages/macOS/CmuxCanvasUI",
    "Packages/macOS/CmuxSwiftRender",
    "Packages/macOS/CmuxSwiftRenderUI",
    "Packages/macOS/CmuxSidebarInterpreterService",
    "Packages/macOS/CmuxSimulator",
    "Packages/macOS/CmuxSudoBroker",
    "Packages/macOS/CmuxSudoBrokerUI",
    "Packages/macOS/CmuxWindowing",
    "Packages/macOS/CmuxCommandPalette",
    "Packages/macOS/CmuxGit",
    "Packages/macOS/CmuxSidebarGit",
    "Packages/macOS/CmuxSidebar",
    "Packages/macOS/CmuxBrowser",
    "Packages/macOS/CmuxNotifications",
    "Packages/macOS/CmuxPhonePush",
    "Packages/macOS/CmuxComputerUse",
    "Packages/macOS/CmuxPanes",
    "Packages/macOS/CmuxWorkspaces",
    "Packages/macOS/CmuxControlSocket",
    "Packages/macOS/CmuxAppKitSupportUI",
    "Packages/macOS/CmuxFeedback",
    "Packages/macOS/CmuxTerminalCore",
    "Packages/macOS/CmuxTerminalImport",
    "Packages/macOS/CmuxTerminal",
    "Packages/macOS/CmuxSettings",
    "Packages/macOS/CmuxTestSupport",
    "Packages/macOS/CmuxSettingsUI",
    "Packages/macOS/CmuxHive",
    "Packages/macOS/CmuxUpdater",
    "Packages/macOS/CmuxUpdaterUI",
    "Packages/macOS/CmuxFoundation",
    "Packages/Shared/CmuxSyntaxHighlighting",
    "Packages/macOS/CmuxFilePreviewCore",
    "Packages/macOS/CmuxCloudBannerCore",
    "Packages/macOS/CmuxCloudTunnelCore",
    "Packages/Shared/CmuxSentryTelemetry",
    "Packages/macOS/CmuxCore",
    "Packages/macOS/CmuxRemoteDaemon",
    "Packages/macOS/CmuxRemoteWorkspace",
    "Packages/macOS/CmuxRemoteSession",
    "vendor/stack-auth-swift-sdk-prerelease",
    "Packages/Shared/CMUXMobileCore",
    "Packages/Shared/CmuxSimulatorStreamKit",
    "Packages/Shared/CmuxIrohTransport",
    "Packages/Shared/CmuxIrxTransport",
    "Packages/iOS/CmuxMobileRPC",
    "Packages/iOS/CmuxMobileTransport",
    "Packages/macOS/CmuxCloudImagePaste",
    "Packages/macOS/CmuxMobileHost",
]

let remotePackages: [Package] = [
    .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .upToNextMajor(from: "2.9.0")),
    .remote(url: "https://github.com/getsentry/sentry-cocoa.git", requirement: .upToNextMajor(from: "9.3.0")),
    .remote(url: "https://github.com/PostHog/posthog-ios.git", requirement: .upToNextMajor(from: "3.41.0")),
    .remote(url: "https://github.com/gonzalezreal/swift-markdown-ui", requirement: .upToNextMajor(from: "2.4.1")),
    .remote(url: "https://github.com/manaflow-ai/iroh-ffi.git", requirement: .exact("1.2.0-cmux.1.ios17")),
]

func products(_ names: [String]) -> [TargetDependency] {
    names.map { useExternalDependencies ? .external(name: $0) : .package(product: $0) }
}

let appProducts: [String] = [
    "CmuxCloud",
    "CmuxCloudTui",
    "CmuxSurfaceCatalogModel",
    "CmuxCloudMachines",
    "CmuxWorkspacePresence",
    "Sparkle",
    "PostHog",
    "Bonsplit",
    "MarkdownUI",
    "CMUXAuthCore",
    "CmuxHive",
    "CmuxAuthRuntime",
    "CmuxAgentChat",
    "CmuxAgentSessionStore",
    "CmuxExtensionKit",
    "CmuxSidebarProviderKit",
    "CmuxExtensionSidebarExamples",
    "CMUXProjectModel",
    "CMUXAgentLaunch",
    "CmuxAgentJournal",
    "CmuxCanvas",
    "CmuxCanvasUI",
    "CmuxSwiftRender",
    "CmuxSwiftRenderUI",
    "CmuxSudoBroker",
    "CmuxSudoBrokerUI",
    "CmuxSidebarInterpreterClient",
    "CmuxSidebarRemoteRender",
    "CmuxSimulator",
    "CmuxSimulatorUI",
    "CmuxSimulatorWorker",
    "CmuxWindowing",
    "CmuxCommandPalette",
    "CmuxGit",
    "CmuxIrohTransport",
    "CmuxIrxTransport",
    "CmuxMobileRPC",
    "IrohLib",
    "CmuxSidebarGit",
    "CmuxSidebar",
    "CmuxBrowser",
    "CmuxNotifications",
    "CmuxPhonePush",
    "CmuxComputerUse",
    "CmuxPanes",
    "CmuxWorkspaces",
    "CMUXDebugLog",
    "CmuxDiffComments",
    "CmuxSettings",
    "CmuxTestSupport",
    "CmuxSettingsUI",
    "CmuxUpdater",
    "CmuxUpdaterUI",
    "CmuxFoundation",
    "CmuxSyntaxHighlighting",
    "CmuxFilePreviewCore",
    "CmuxCloudBannerCore",
    "CmuxSentryReporting",
    "CmuxSentryScrubbing",
    "CmuxCore",
    "CmuxRemoteDaemon",
    "CmuxRemoteWorkspace",
    "CmuxRemoteSession",
    "StackAuth",
    "CMUXMobileCore",
    "CmuxSimulatorStreamKit",
    "CmuxMobileTransport",
    "CmuxCloudImagePaste",
    "CmuxMobileHost",
]

let cliProducts: [String] = [
    "CmuxSurfaceCatalogModel",
    "CMUXAgentLaunch",
    "CmuxAgentJournal",
    "CmuxControlSocket",
    "CmuxTerminalCore",
    "CmuxTerminalImport",
    "CMUXDebugLog",
    "CmuxCore",
    "CmuxSwiftRender",
    "CmuxSwiftRenderUI",
    "CmuxSudoBroker",
    "CmuxSidebarInterpreterClient",
    "CmuxSimulator",
    "CmuxSettings",
    "CmuxFoundation",
    "CmuxSentryReporting",
    "CmuxSentryScrubbing",
]

let tunnelProducts: [String] = [
    "WireGuardKit",
    "CmuxCloudTunnelCore",
]

let unitTestProducts: [String] = [
    "CmuxSurfaceCatalogModel",
    "CmuxCloudMachines",
    "CmuxWorkspacePresence",
    "CMUXAuthCore",
    "CmuxHive",
    "CmuxAuthRuntime",
    "CMUXAgentLaunch",
    "CmuxAgentJournal",
    "CmuxControlSocket",
    "CmuxIrohTransport",
    "CmuxIrxTransport",
    "IrohLib",
    "CmuxMobileRPC",
    "CMUXMobileCore",
    "CmuxMobileTransport",
    "CmuxCanvas",
    "Sentry",
    "CmuxFoundation",
    "CmuxSettings",
    "CmuxWorkspaces",
    "CmuxAppKitSupportUI",
    "CmuxAgentSessionStore",
    "CmuxBrowser",
    "CmuxCommandPalette",
    "CmuxSidebarProviderKit",
    "CmuxPhonePush",
    "CmuxComputerUse",
    "CmuxWindowing",
    "CmuxCore",
    "CmuxSyntaxHighlighting",
    "CmuxFilePreviewCore",
    "CmuxCloudBannerCore",
    "CmuxCloudTunnelCore",
    "Bonsplit",
    "CmuxSudoBroker",
    "CmuxSudoBrokerUI",
    "CMUXDebugLog",
    "CmuxDiffComments",
    "CmuxAgentChat",
    "CmuxCloudImagePaste",
    "CmuxMobileHost",
]

let cliTestProducts: [String] = [
    "CMUXAgentLaunch",
    "CmuxAgentJournal",
    "CmuxFoundation",
    "CmuxSettings",
]

// Build settings copied from cmux.xcodeproj.
let projectSettingsDebug: SettingsDictionary = [
        "ALWAYS_SEARCH_USER_PATHS": .string("NO"),
        "CLANG_ANALYZER_NONNULL": .string("YES"),
        "CLANG_ENABLE_MODULES": .string("YES"),
        "CLANG_ENABLE_OBJC_ARC": .string("YES"),
        "COPY_PHASE_STRIP": .string("NO"),
        "DEBUG_INFORMATION_FORMAT": .string("dwarf"),
        "ENABLE_STRICT_OBJC_MSGSEND": .string("YES"),
        "ENABLE_TESTABILITY": .string("YES"),
        "GCC_DYNAMIC_NO_PIC": .string("NO"),
        "GCC_NO_COMMON_BLOCKS": .string("YES"),
        "GCC_OPTIMIZATION_LEVEL": .string("0"),
        "GCC_PREPROCESSOR_DEFINITIONS": .array(["DEBUG=1", "$(inherited)"]),
        "GCC_WARN_64_TO_32_BIT_CONVERSION": .string("YES"),
        "GCC_WARN_ABOUT_RETURN_TYPE": .string("YES_ERROR"),
        "GCC_WARN_UNDECLARED_SELECTOR": .string("YES"),
        "GCC_WARN_UNINITIALIZED_AUTOS": .string("YES_AGGRESSIVE"),
        "GCC_WARN_UNUSED_FUNCTION": .string("YES"),
        "GCC_WARN_UNUSED_VARIABLE": .string("YES"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MTL_ENABLE_DEBUG_INFO": .string("INCLUDE_SOURCE"),
        "MTL_FAST_MATH": .string("YES"),
        "ONLY_ACTIVE_ARCH": .string("YES"),
        "SDKROOT": .string("macosx"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG"),
        "SWIFT_OPTIMIZATION_LEVEL": .string("-Onone"),
    ]
let projectSettingsRelease: SettingsDictionary = [
        "ALWAYS_SEARCH_USER_PATHS": .string("NO"),
        "CLANG_ANALYZER_NONNULL": .string("YES"),
        "CLANG_ENABLE_MODULES": .string("YES"),
        "CLANG_ENABLE_OBJC_ARC": .string("YES"),
        "COPY_PHASE_STRIP": .string("NO"),
        "DEBUG_INFORMATION_FORMAT": .string("dwarf-with-dsym"),
        "ENABLE_NS_ASSERTIONS": .string("NO"),
        "ENABLE_STRICT_OBJC_MSGSEND": .string("YES"),
        "GCC_NO_COMMON_BLOCKS": .string("YES"),
        "GCC_WARN_64_TO_32_BIT_CONVERSION": .string("YES"),
        "GCC_WARN_ABOUT_RETURN_TYPE": .string("YES_ERROR"),
        "GCC_WARN_UNDECLARED_SELECTOR": .string("YES"),
        "GCC_WARN_UNINITIALIZED_AUTOS": .string("YES_AGGRESSIVE"),
        "GCC_WARN_UNUSED_FUNCTION": .string("YES"),
        "GCC_WARN_UNUSED_VARIABLE": .string("YES"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MTL_ENABLE_DEBUG_INFO": .string("NO"),
        "MTL_FAST_MATH": .string("YES"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "SDKROOT": .string("macosx"),
        "SWIFT_COMPILATION_MODE": .string("wholemodule"),
        "SWIFT_OPTIMIZATION_LEVEL": .string("-O"),
    ]
let appSettingsDebug: SettingsDictionary = [
        "ASSETCATALOG_COMPILER_APPICON_NAME": .string("AppIcon-Debug"),
        "CMUX_AUTH_CALLBACK_SCHEME": .string("cmux-dev"),
        "CMUX_IROH_RELAY_POLICY_KEY_ID": .string("cmux-staging-relay-policy-2026-07"),
        "CMUX_IROH_RELAY_POLICY_NEXT_KEY_ID": .string("cmux-staging-relay-policy-2026-08"),
        "CMUX_IROH_RELAY_POLICY_NEXT_PUBLIC_KEY_BASE64": .string("KnOZ6gKmH05Mrfan2tXgwRygBKxcSUue4bp34udiQFA="),
        "CMUX_IROH_RELAY_POLICY_PUBLIC_KEY_BASE64": .string("Otx9S0B4d/tlwIKYRf5evJaqhjCltFLPjMfXrLFd6lk="),
        "CMUX_SIDEBAR_EXTENSION_POINT_ID": .string("com.cmuxterm.app.cmux.sidebar"),
        "CODE_SIGN_ENTITLEMENTS": .string(""),
        "CODE_SIGN_STYLE": .string("Automatic"),
        "COMBINE_HIDPI_IMAGES": .string("YES"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "DEVELOPMENT_TEAM": .string(""),
        "ENABLE_HARDENED_RUNTIME": .string("NO"),
        "GENERATE_INFOPLIST_FILE": .string("NO"),
        "INFOPLIST_FILE": .string("Resources/Info.plist"),
        "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path/../Frameworks"]),
        "MARKETING_VERSION": .string("0.64.25"),
        "OTHER_LDFLAGS": .array(["-lc++", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "IOSurface", "-framework", "UniformTypeIdentifiers", "-framework", "Carbon"]),
        "OTHER_SWIFT_FLAGS": .array(["-Xllvm", "-global-isel=0"]),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.app.debug"),
        "PRODUCT_NAME": .string("cmux DEV"),
        "SPARKLE_PUBLIC_KEY": .string("avjcgKibf1FTvhIjLBxhd+0HSpsXU4D0IGlVk8cgqRc="),
        "SWIFT_EMIT_LOC_STRINGS": .string("YES"),
        "SWIFT_ENABLE_BATCH_MODE": .string("NO"),
        "SWIFT_OBJC_BRIDGING_HEADER": .string("cmux-Bridging-Header.h"),
        "SWIFT_OBJC_INTERFACE_HEADER_NAME": .string(""),
        "SWIFT_VERSION": .string("5.0"),
    ]
let appSettingsRelease: SettingsDictionary = [
        "ASSETCATALOG_COMPILER_APPICON_NAME": .string("AppIcon"),
        "CMUX_AUTH_CALLBACK_SCHEME": .string("cmux"),
        "CMUX_IROH_RELAY_POLICY_KEY_ID": .string("cmux-production-relay-policy-2026-07"),
        "CMUX_IROH_RELAY_POLICY_NEXT_KEY_ID": .string("cmux-production-relay-policy-2026-08"),
        "CMUX_IROH_RELAY_POLICY_NEXT_PUBLIC_KEY_BASE64": .string("k+FND+WlELCkHs9QnWg1TfTuHXBwyv2907umX+mUOOU="),
        "CMUX_IROH_RELAY_POLICY_PUBLIC_KEY_BASE64": .string("qoBinRqX4TI1Ro6xAuOQxKUkeZT3pkFJuERP/+R+9aw="),
        "CMUX_SIDEBAR_EXTENSION_POINT_ID": .string("com.cmuxterm.app.cmux.sidebar"),
        "CODE_SIGN_ENTITLEMENTS": .string("Resources/cmux.entitlements"),
        "CODE_SIGN_STYLE": .string("Automatic"),
        "COMBINE_HIDPI_IMAGES": .string("YES"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "DEVELOPMENT_TEAM": .string(""),
        "ENABLE_HARDENED_RUNTIME": .string("NO"),
        "GENERATE_INFOPLIST_FILE": .string("NO"),
        "INFOPLIST_FILE": .string("Resources/Info.plist"),
        "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path/../Frameworks"]),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "OTHER_LDFLAGS": .array(["-lc++", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "IOSurface", "-framework", "UniformTypeIdentifiers", "-framework", "Carbon"]),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.app"),
        "PRODUCT_NAME": .string("cmux"),
        "SPARKLE_PUBLIC_KEY": .string("avjcgKibf1FTvhIjLBxhd+0HSpsXU4D0IGlVk8cgqRc="),
        "SWIFT_EMIT_LOC_STRINGS": .string("YES"),
        "SWIFT_OBJC_BRIDGING_HEADER": .string("cmux-Bridging-Header.h"),
        "SWIFT_VERSION": .string("5.0"),
    ]
let dockTileSettingsDebug: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Manual"),
        "COMBINE_HIDPI_IMAGES": .string("YES"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "DEVELOPMENT_TEAM": .string(""),
        "ENABLE_USER_SCRIPT_SANDBOXING": .string("YES"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "INFOPLIST_KEY_CFBundleDisplayName": .string("cmux Dock Tile Plugin"),
        "INFOPLIST_KEY_NSHumanReadableCopyright": .string(""),
        "INFOPLIST_KEY_NSPrincipalClass": .string(""),
        "INSTALL_PATH": .string("$(LOCAL_LIBRARY_DIR)/Bundles"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.app.docktileplugin.debug"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "PROVISIONING_PROFILE_SPECIFIER": .string(""),
        "SKIP_INSTALL": .string("YES"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG $(inherited)"),
        "SWIFT_VERSION": .string("5.0"),
        "WRAPPER_EXTENSION": .string("plugin"),
    ]
let dockTileSettingsRelease: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Manual"),
        "COMBINE_HIDPI_IMAGES": .string("YES"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "DEVELOPMENT_TEAM": .string(""),
        "ENABLE_USER_SCRIPT_SANDBOXING": .string("YES"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "INFOPLIST_KEY_CFBundleDisplayName": .string("cmux Dock Tile Plugin"),
        "INFOPLIST_KEY_NSHumanReadableCopyright": .string(""),
        "INFOPLIST_KEY_NSPrincipalClass": .string(""),
        "INSTALL_PATH": .string("$(LOCAL_LIBRARY_DIR)/Bundles"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.app.docktileplugin"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "PROVISIONING_PROFILE_SPECIFIER": .string(""),
        "SKIP_INSTALL": .string("YES"),
        "SWIFT_VERSION": .string("5.0"),
        "WRAPPER_EXTENSION": .string("plugin"),
    ]
let tunnelSettingsDebug: SettingsDictionary = [
        "CMUX_TEAM_ID_PREFIX": .string("7WLXT3NR37."),
        "CODE_SIGN_ENTITLEMENTS": .string(""),
        "CODE_SIGN_STYLE": .string("Automatic"),
        "COMBINE_HIDPI_IMAGES": .string("YES"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "DEVELOPMENT_TEAM": .string(""),
        "ENABLE_USER_SCRIPT_SANDBOXING": .string("NO"),
        "GENERATE_INFOPLIST_FILE": .string("NO"),
        "INFOPLIST_FILE": .string("TunnelExtension/Info.plist"),
        "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path/../Frameworks"]),
        "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(BUILT_PRODUCTS_DIR)"]),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.app.debug.tunnel"),
        "PRODUCT_MODULE_NAME": .string("cmuxTunnel"),
        "PRODUCT_NAME": .string("cmuxTunnel"),
        "PROVISIONING_PROFILE_SPECIFIER": .string(""),
        "SKIP_INSTALL": .string("YES"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG $(inherited)"),
        "SWIFT_VERSION": .string("5.0"),
        "WRAPPER_EXTENSION": .string("systemextension"),
    ]
let tunnelSettingsRelease: SettingsDictionary = [
        "CMUX_TEAM_ID_PREFIX": .string("7WLXT3NR37."),
        "CODE_SIGN_ENTITLEMENTS": .string(""),
        "CODE_SIGN_STYLE": .string("Automatic"),
        "COMBINE_HIDPI_IMAGES": .string("YES"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "DEVELOPMENT_TEAM": .string(""),
        "ENABLE_USER_SCRIPT_SANDBOXING": .string("NO"),
        "GENERATE_INFOPLIST_FILE": .string("NO"),
        "INFOPLIST_FILE": .string("TunnelExtension/Info.plist"),
        "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path/../Frameworks"]),
        "LIBRARY_SEARCH_PATHS": .array(["$(inherited)", "$(BUILT_PRODUCTS_DIR)"]),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.app.tunnel"),
        "PRODUCT_MODULE_NAME": .string("cmuxTunnel"),
        "PRODUCT_NAME": .string("cmuxTunnel"),
        "PROVISIONING_PROFILE_SPECIFIER": .string(""),
        "SKIP_INSTALL": .string("YES"),
        "SWIFT_COMPILATION_MODE": .string("wholemodule"),
        "SWIFT_OPTIMIZATION_LEVEL": .string("-O"),
        "SWIFT_VERSION": .string("5.0"),
        "WRAPPER_EXTENSION": .string("systemextension"),
    ]
let cliSettingsDebug: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Automatic"),
        "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path", "@executable_path/../Frameworks", "@executable_path/../../Frameworks"]),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "PRODUCT_MODULE_NAME": .string("cmux_cli"),
        "PRODUCT_NAME": .string("cmux"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG"),
        "SWIFT_OPTIMIZATION_LEVEL": .string("-Onone"),
        "SWIFT_VERSION": .string("5.0"),
    ]
let cliSettingsRelease: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Automatic"),
        "LD_RUNPATH_SEARCH_PATHS": .array(["$(inherited)", "@executable_path", "@executable_path/../Frameworks", "@executable_path/../../Frameworks"]),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "PRODUCT_MODULE_NAME": .string("cmux_cli"),
        "PRODUCT_NAME": .string("cmux"),
        "SWIFT_COMPILATION_MODE": .string("wholemodule"),
        "SWIFT_OPTIMIZATION_LEVEL": .string("-O"),
        "SWIFT_VERSION": .string("5.0"),
    ]
let uiTestsSettingsDebug: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Automatic"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("YES"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.appuitests"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG $(inherited)"),
        "SWIFT_VERSION": .string("5.0"),
        "TEST_TARGET_NAME": .string("cmux"),
    ]
let uiTestsSettingsRelease: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Automatic"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.appuitests"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "SWIFT_VERSION": .string("5.0"),
        "TEST_TARGET_NAME": .string("cmux"),
    ]
let unitTestsSettingsDebug: SettingsDictionary = [
        "BUNDLE_LOADER": .string("$(TEST_HOST)"),
        "CODE_SIGN_STYLE": .string("Automatic"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "INFOPLIST_KEY_NSPrincipalClass": .string("CmuxTestsPrincipal"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("YES"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.apptests"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG $(inherited)"),
        "SWIFT_OBJC_INTERFACE_HEADER_NAME": .string(""),
        "SWIFT_VERSION": .string("5.0"),
        "TEST_HOST": .string("$(BUILT_PRODUCTS_DIR)/cmux DEV.app/Contents/MacOS/cmux DEV"),
        "TEST_TARGET_NAME": .string("cmux"),
    ]
let unitTestsSettingsRelease: SettingsDictionary = [
        "BUNDLE_LOADER": .string("$(TEST_HOST)"),
        "CODE_SIGN_STYLE": .string("Automatic"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "INFOPLIST_KEY_NSPrincipalClass": .string("CmuxTestsPrincipal"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.apptests"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "SWIFT_OBJC_INTERFACE_HEADER_NAME": .string(""),
        "SWIFT_VERSION": .string("5.0"),
        "TEST_HOST": .string("$(BUILT_PRODUCTS_DIR)/cmux.app/Contents/MacOS/cmux"),
        "TEST_TARGET_NAME": .string("cmux"),
    ]
let cliTestsSettingsDebug: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Automatic"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("YES"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.clitests"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string("DEBUG $(inherited)"),
        "SWIFT_VERSION": .string("5.0"),
    ]
let cliTestsSettingsRelease: SettingsDictionary = [
        "CODE_SIGN_STYLE": .string("Automatic"),
        "CURRENT_PROJECT_VERSION": .string("106"),
        "GENERATE_INFOPLIST_FILE": .string("YES"),
        "MACOSX_DEPLOYMENT_TARGET": .string("14.0"),
        "MARKETING_VERSION": .string("0.64.25"),
        "ONLY_ACTIVE_ARCH": .string("NO"),
        "PRODUCT_BUNDLE_IDENTIFIER": .string("com.cmuxterm.clitests"),
        "PRODUCT_NAME": .string("$(TARGET_NAME)"),
        "SWIFT_VERSION": .string("5.0"),
    ]


func settings(_ debug: SettingsDictionary, _ release: SettingsDictionary) -> Settings {
    .settings(
        configurations: [
            .debug(name: "Debug", settings: debug),
            .release(name: "Release", settings: release),
        ],
        defaultSettings: .none
    )
}

// Script phases, in the order cmux.xcodeproj runs them after Sources/Resources.
let appScripts: [TargetScript] = [
    .post(
        script: "\"${SRCROOT}/scripts/compress-markdown-viewer-assets.sh\"",
        name: "Compress Markdown Viewer Assets",
        inputPaths: ["$(SRCROOT)/scripts/compress-markdown-viewer-assets.sh", "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/markdown-viewer"],
        basedOnDependencyAnalysis: false
    ),
    .post(
        script: "\"${SRCROOT}/scripts/write-sidebar-extension-point.sh\"",
        name: "Write Extension Point",
        inputPaths: ["$(SRCROOT)/scripts/write-sidebar-extension-point.sh"],
        outputPaths: ["$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Extensions/$(CMUX_SIDEBAR_EXTENSION_POINT_ID).appextensionpoint"],
        basedOnDependencyAnalysis: false
    ),
    // cmux.xcodeproj copies these built products with Copy Files phases. Tuist's
    // copyFiles only takes source files, so the spike copies them with a script.
    .post(
        script: """
        set -euo pipefail
        ditto "${BUILT_PRODUCTS_DIR}/CmuxDockTilePlugin.plugin" "${TARGET_BUILD_DIR}/${PLUGINS_FOLDER_PATH}/CmuxDockTilePlugin.plugin"
        mkdir -p "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
        ditto "${BUILT_PRODUCTS_DIR}/cmux" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin/cmux"
        """,
        name: "Copy Dock Tile Plugin and CLI",
        inputPaths: ["$(BUILT_PRODUCTS_DIR)/CmuxDockTilePlugin.plugin", "$(BUILT_PRODUCTS_DIR)/cmux"],
        outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/cmux"]
    ),
    .post(
        script: """
        rm -f "${TARGET_TEMP_DIR}"/cmux-diff-sidecar.arch-*.min-*.stamp
        CMUX_DIFF_SIDECAR_ARCHS="${ARCHS}" CMUX_DIFF_SIDECAR_MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET}" CMUX_DIFF_SIDECAR_STAMP="${TARGET_TEMP_DIR}/cmux-diff-sidecar.arch-${ARCHS}.min-${MACOSX_DEPLOYMENT_TARGET}.stamp" "${SRCROOT}/scripts/build-diff-sidecar.sh"
        """,
        name: "Build Diff Sidecar",
        inputPaths: [
            "$(SRCROOT)/Native/DiffSidecar/Cargo.toml", "$(SRCROOT)/Native/DiffSidecar/Cargo.lock",
            "$(SRCROOT)/Native/DiffSidecar/rust-toolchain.toml", "$(SRCROOT)/Native/DiffSidecar/src/benchmark.rs",
            "$(SRCROOT)/Native/DiffSidecar/src/lib.rs", "$(SRCROOT)/Native/DiffSidecar/src/main.rs",
            "$(SRCROOT)/Native/DiffSidecar/src/manifest.rs", "$(SRCROOT)/Native/DiffSidecar/src/protocol.rs",
            "$(SRCROOT)/Native/DiffSidecar/src/server.rs", "$(SRCROOT)/scripts/build-diff-sidecar.sh",
            "$(SRCROOT)/scripts/run-diff-sidecar-cargo.sh", "$(SRCROOT)/scripts/verify-diff-sidecar-artifact.sh",
        ],
        outputPaths: [
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/cmux-diff-sidecar",
            "$(TARGET_TEMP_DIR)/cmux-diff-sidecar.arch-$(ARCHS).min-$(MACOSX_DEPLOYMENT_TARGET).stamp",
        ]
    ),
    .post(
        script: "\"${SRCROOT}/scripts/build-command-palette-nucleo-ffi.sh\"",
        name: "Build Command Palette Nucleo FFI",
        inputPaths: [
            "$(SRCROOT)/Native/CommandPaletteNucleoFFI/Cargo.toml", "$(SRCROOT)/Native/CommandPaletteNucleoFFI/Cargo.lock",
            "$(SRCROOT)/Native/CommandPaletteNucleoFFI/src/lib.rs", "$(SRCROOT)/scripts/build-command-palette-nucleo-ffi.sh",
        ],
        outputPaths: ["$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/libcmux_command_palette_nucleo_ffi.dylib"]
    ),
    .post(
        script: "\"${SRCROOT}/scripts/build-app-bundled-resources.sh\"",
        name: "Build App Bundled Resources"
    ),
    .post(
        script: "\"${SRCROOT}/scripts/build-plain-text-paste-worker.sh\" \"${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin/cmux-paste-text-worker\" \"${ARCHS}\"",
        name: "Build Plain Text Paste Worker",
        inputPaths: ["$(SRCROOT)/scripts/build-plain-text-paste-worker.sh", "$(SRCROOT)/workers/cmux-paste-text/main.m"],
        outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/cmux-paste-text-worker"],
        basedOnDependencyAnalysis: false
    ),
    .post(
        script: """
        set -euo pipefail
        BIN_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
        PROVIDERS="codex claude opencode pi"
        for provider in $PROVIDERS; do
          if [ -e "${SRCROOT}/Resources/bin/${provider}" ]; then
            echo "error: provider executable must not be checked in at Resources/bin/${provider}" >&2
            exit 1
          fi
          if [ -e "${BIN_DIR}/${provider}" ]; then
            rm -rf "${BIN_DIR:?}/${provider}"
          fi
          if [ -e "${BIN_DIR}/${provider}" ]; then
            echo "error: provider executable must not be bundled at ${BIN_DIR}/${provider}" >&2
            exit 1
          fi
        done
        """,
        name: "Reject Bundled Provider Binaries",
        basedOnDependencyAnalysis: false
    ),
]

let cliResourceFiles: [CopyFileElement] = [
    "Resources/bin/cmux-amp-wrapper", "Resources/bin/cmux-claude-wrapper", "Resources/bin/cmux-codex-wrapper",
    "Resources/bin/cmux-hermes-agent-wrapper", "Resources/bin/cmux-hermes-python-wrapper",
    "Resources/bin/cmux-hermes-sitecustomize.py", "Resources/bin/cmux-pi-wrapper", "Resources/bin/cmux-sudo",
    "Resources/bin/grok", "Resources/bin/open", "scripts/setup-pam-tid.sh",
    "Resources/bin/start-cmux-profiling", "Resources/bin/submit-cmux-profile",
]

let app = Target.target(
    name: "cmux",
    destinations: .macOS,
    product: .app,
    productName: "cmux",
    bundleId: "com.cmuxterm.app",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .file(path: "Resources/Info.plist"),
    // Globs replace the 2,420 explicit file references: a new Swift file under
    // Sources/ joins the app with no project edit.
    sources: [
        .glob("Sources/**/*.swift", excluding: ["Sources/AppIconDockTilePlugin.swift"]),
        .glob("Sources/**/*.c"),
        "CLI/CodexTeamsAppServerProcess.swift",
        "CLI/CodexTeamsPOSIXSupport.swift",
    ],
    resources: [
        .folderReference(path: "Resources/agent-session-react"),
        .folderReference(path: "Resources/agent-session-solid"),
        .folderReference(path: "Resources/feed-tui"),
        .folderReference(path: "Resources/markdown-viewer"),
        .folderReference(path: "skills/cmux-cua"),
        "Assets.xcassets",
        "Resources/*.lproj/cloud-agent-skill.md",
        "Resources/cmux.sdef",
        "Resources/ComputerUseHelperIcon.icns",
        "Resources/ConfigPackErrors.xcstrings",
        "Resources/InfoPlist.xcstrings",
        "Resources/Localizable.xcstrings",
        "Resources/opencode-plugin.js",
        "LICENSE",
        "THIRD_PARTY_LICENSES.md",
        "Resources/ghostty/terminfo/78/xterm-ghostty",
    ],
    copyFiles: [
        .resources(name: "Copy CLI", subpath: "bin", files: cliResourceFiles),
    ],
    scripts: appScripts,
    dependencies: [
        .target(name: "cmux-cli"),
        .target(name: "CmuxDockTilePlugin"),
        .target(name: "cmuxTunnelExtension"),
        .xcframework(path: "GhosttyKit.xcframework"),
    ] + products(appProducts),
    settings: settings(appSettingsDebug, appSettingsRelease)
)

let dockTilePlugin = Target.target(
    name: "CmuxDockTilePlugin",
    destinations: .macOS,
    product: .bundle,
    bundleId: "com.cmuxterm.app.docktileplugin",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["Sources/App/AppBundleIconPersistencePolicy.swift", "Sources/AppIconDockTilePlugin.swift"],
    settings: settings(dockTileSettingsDebug, dockTileSettingsRelease)
)

let tunnelExtension = Target.target(
    name: "cmuxTunnelExtension",
    destinations: .macOS,
    product: .systemExtension,
    productName: "cmuxTunnel",
    bundleId: "com.cmuxterm.app.tunnel",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .file(path: "TunnelExtension/Info.plist"),
    sources: ["TunnelExtension/*.swift"],
    resources: ["TunnelExtension/InfoPlist.xcstrings"],
    scripts: [
        .pre(
            script: "\"${SRCROOT}/scripts/build-wireguard-go.sh\"",
            name: "Build wireguard-go",
            inputPaths: [
                "$(SRCROOT)/scripts/build-wireguard-go.sh",
                "$(SRCROOT)/vendor/WireGuardKit/Sources/WireGuardKitGo/api-apple.go",
                "$(SRCROOT)/vendor/WireGuardKit/Sources/WireGuardKitGo/go.mod",
                "$(SRCROOT)/vendor/WireGuardKit/Sources/WireGuardKitGo/go.sum",
            ],
            outputPaths: ["$(BUILT_PRODUCTS_DIR)/libwg-go.a"]
        ),
    ],
    dependencies: products(tunnelProducts),
    settings: settings(tunnelSettingsDebug, tunnelSettingsRelease)
)

let cli = Target.target(
    name: "cmux-cli",
    destinations: .macOS,
    product: .commandLineTool,
    productName: "cmux",
    bundleId: "com.cmuxterm.cli",
    deploymentTargets: .macOS("14.0"),
    sources: .sourceFilesList(globs: [.glob("CLI/**/*.swift")] + ["Sources/AgentHibernation/AgentHibernationLifecycleState.swift", "Sources/AgentProcessBindingResolution.swift", "Sources/AutomationConfigMutationCoordinator.swift", "Sources/AutomationConfigStore.swift", "Sources/AutomationConfigStoreError.swift", "Sources/AutomationPayloadRedactor.swift", "Sources/AutomationRule.swift", "Sources/AutomationWebhookPolicy.swift", "Sources/AutomationWebhookRedirectDelegate.swift", "Sources/Surfaces/CmuxTuiRemoteRouting.swift", "Sources/JSONCObjectEditor+Remove.swift", "Sources/JSONCObjectEditor+Set.swift", "Sources/JSONCParser.swift", "Sources/RemoteInitialCommandBootstrap.swift", "Sources/RemoteInteractiveShellBootstrapBuilder+WorkingDirectory.swift", "Sources/RemoteInteractiveShellBootstrapBuilder.swift", "Sources/RemoteRelayZshBootstrap.swift", "Sources/RemoteSessionBundledResourceLoader.swift", "Sources/SSHPTYAttachStartupCommandBuilder.swift"].map { SourceFileGlob.glob(Path(stringLiteral: $0)) }),
    dependencies: products(cliProducts),
    settings: settings(cliSettingsDebug, cliSettingsRelease)
)

let unitTests = Target.target(
    name: "cmuxTests",
    destinations: .macOS,
    product: .unitTests,
    bundleId: "com.cmuxterm.apptests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: .sourceFilesList(globs: [
        .glob("cmuxTests/**/*.swift"),
        .glob("cmuxTests/**/*.m"),
        .glob("cmuxCLITestSupport/**/*.swift"),
    ] + ["CLI/AgentHookNotificationPolicy.swift", "CLI/BrowserValueTextFormatter.swift", "CLI/CLIError.swift", "CLI/CLISocketPathResolver.swift", "Packages/macOS/CmuxCloudTunnelCore/Tests/CmuxCloudTunnelCoreTests/CloudTunnelProviderStartGateTests.swift", "CLI/CMUXCLI+AutoNaming.swift", "CLI/CodexTeamsApprovalBridge.swift", "CLI/FeedEventClassifier.swift", "CLI/FreestyleInteractiveShellScript.swift", "CLI/LocalTmuxCommandBuilder.swift", "CLI/LocalTmuxProcessRunner.swift", "CLI/LocalTmuxSessionBinding.swift", "CLI/LocalTmuxSessionIdentity.swift", "CLI/LocalTmuxSessionListParser.swift", "CLI/SSHPTYAttachReconnectInputFilter.swift", "CLI/SSHPTYAttachReconnectInputFilterControl.swift", "CLI/SSHPTYAttachReconnectInputFilterPumpIO.swift", "CLI/SSHPTYAttachReconnectInputFilterSequenceMatch.swift", "CLI/SSHPTYAttachReconnectInputFilterState.swift", "Sources/TerminalSelectionAccessibilityNotifier.swift", "CLI/VMMachineTerminalResolution.swift", "CLI/VMRemoteWorkspaceResolver.swift"].map { SourceFileGlob.glob(Path(stringLiteral: $0)) }),
    dependencies: [.target(name: "cmux")] + products(unitTestProducts),
    settings: settings(unitTestsSettingsDebug, unitTestsSettingsRelease)
)

let cliTests = Target.target(
    name: "cmuxCLITests",
    destinations: .macOS,
    product: .unitTests,
    bundleId: "com.cmuxterm.clitests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: .sourceFilesList(globs: [
        .glob("cmuxCLITests/**/*.swift"),
        .glob("cmuxCLITestSupport/**/*.swift"),
    ] + ["CLI/CodexTeamsAppServerProcess.swift", "CLI/CodexTeamsPOSIXSupport.swift"].map { SourceFileGlob.glob(Path(stringLiteral: $0)) }),
    dependencies: [.target(name: "cmux-cli")] + products(cliTestProducts),
    settings: settings(cliTestsSettingsDebug, cliTestsSettingsRelease)
)

let uiTests = Target.target(
    name: "cmuxUITests",
    destinations: .macOS,
    product: .uiTests,
    bundleId: "com.cmuxterm.appuitests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: ["cmuxUITests/**/*.swift"],
    dependencies: [.target(name: "cmux")],
    settings: settings(uiTestsSettingsDebug, uiTestsSettingsRelease)
)

let project = Project(
    // Named CmuxTuist so the spike can sit next to cmux.xcodeproj. An adoption
    // would name it cmux and stop tracking cmux.xcodeproj in git.
    name: "CmuxTuist",
    options: .options(
        automaticSchemesOptions: .enabled(),
        disableBundleAccessors: true,
        disableSynthesizedResourceAccessors: true
    ),
    packages: useExternalDependencies ? [] : localPackagePaths.map { .local(path: Path(stringLiteral: $0)) } + remotePackages,
    settings: settings(projectSettingsDebug, projectSettingsRelease),
    targets: [app, dockTilePlugin, tunnelExtension, cli, unitTests, cliTests, uiTests]
)
