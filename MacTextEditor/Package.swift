// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacTextEditor",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ScintillaCocoaBridge",
            path: "Vendor/scintilla",
            exclude: [
                "cocoa/Scintilla",
                "cocoa/ScintillaTest",
                "cocoa/res"
            ],
            sources: [
                "bridge/ScintillaCocoaBridge.mm",
                "cocoa/InfoBar.mm",
                "cocoa/PlatCocoa.mm",
                "cocoa/ScintillaCocoa.mm",
                "cocoa/ScintillaView.mm",
                "src/AutoComplete.cxx",
                "src/CallTip.cxx",
                "src/CaseConvert.cxx",
                "src/CaseFolder.cxx",
                "src/CellBuffer.cxx",
                "src/ChangeHistory.cxx",
                "src/CharClassify.cxx",
                "src/CharacterCategoryMap.cxx",
                "src/CharacterType.cxx",
                "src/ContractionState.cxx",
                "src/DBCS.cxx",
                "src/Decoration.cxx",
                "src/Document.cxx",
                "src/EditModel.cxx",
                "src/EditView.cxx",
                "src/Editor.cxx",
                "src/Geometry.cxx",
                "src/Indicator.cxx",
                "src/KeyMap.cxx",
                "src/LineMarker.cxx",
                "src/MarginView.cxx",
                "src/PerLine.cxx",
                "src/PositionCache.cxx",
                "src/RESearch.cxx",
                "src/RunStyles.cxx",
                "src/ScintillaBase.cxx",
                "src/Selection.cxx",
                "src/Style.cxx",
                "src/UndoHistory.cxx",
                "src/UniConversion.cxx",
                "src/UniqueString.cxx",
                "src/ViewStyle.cxx",
                "src/XPM.cxx"
            ],
            publicHeadersPath: "bridge/include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("cocoa")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "MacTextEditor",
            dependencies: ["ScintillaCocoaBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
