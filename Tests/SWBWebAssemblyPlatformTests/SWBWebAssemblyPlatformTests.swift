//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBCore
import SWBMacro
import SWBProtocol
import SWBTestSupport
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SWBWebAssemblyPlatformTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func wasmSwiftSDKRunDestination() async throws {
        try await withTemporaryDirectory { tmpDir in
            let clangCompilerPath = try await self.clangCompilerPath
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyLibrary",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.c"),
                                TestBuildFile("SwiftFile.swift"),
                            ]),
                        ]),
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            // Swift SDK contents
            let sdkManifestContents = """
            {
                "schemaVersion" : "4.0",
                "targetTriples" : {
                    "wasm32-unknown-wasip1" : {
                        "sdkRootPath" : "WASI.sdk",
                        "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "toolsetPaths" : [
                            "toolset.json"
                        ]
                    }
                }
            }
            """
            let sdkManifestDir = tmpDir
            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestDir.join("swift-sdk.json"), waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : {
                        "extraCLIOptions" : [
                            "-static-stdlib"
                        ]
                    }
                }
                """)
            })

            let sysroot = sdkManifestDir.join("WASI.sdk")
            let sdkroot = sdkManifestDir.join("WASI.sdk")

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains([
                        [clangCompilerPath.str],
                        ["-target", "wasm32-unknown-wasip1"],
                        ["--sysroot", sysroot.str],
                    ].reduce([], +))
                }

                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        ["-resource-dir", sdkManifestDir.join("swift.xctoolchain").join("usr").join("lib").join("swift_static").str],
                        ["-static-stdlib"],
                        ["-sdk", sdkroot.str],
                        ["-sysroot", sysroot.str],
                        ["-target", "wasm32-unknown-wasip1"],
                    ].reduce([], +))
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func swiftSDKRunDestinationRemapUsesManifestSDKRoot() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await Self.makeCore()

            let sdkManifestContents = """
            {
                "schemaVersion" : "4.0",
                "targetTriples" : {
                    "wasm32-unknown-wasip1" : {
                        "sdkRootPath" : "WASI.sdk",
                        "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "toolsetPaths" : [
                            "toolset.json"
                        ]
                    }
                }
            }
            """
            let sdkManifestPath = tmpDir.join("swift-sdk.json")
            try localFS.createDirectory(tmpDir)
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false) {
                $0.write(sdkManifestContents)
            }
            try await localFS.writeFileContents(tmpDir.join("toolset.json"), waitForNewTimestamp: false) { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0"
                }
                """)
            }

            let workspace = try TestWorkspace("Workspace", projects: [
                TestProject(
                    "aProject",
                    sourceRoot: tmpDir.join("Project"),
                    groupTree: TestGroup("SomeFiles", children: [
                        TestFile("SourceFile.swift"),
                    ]),
                    targets: [
                        TestStandardTarget(
                            "MyLibrary",
                            type: .staticLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "linux",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["SourceFile.swift"]),
                            ]
                        ),
                    ]
                )
            ]).load(core)

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
            let project = try #require(workspace.projects.only)
            let target = try #require(project.targets.only)
            let buildRequest = BuildRequest(
                parameters: parameters,
                buildTargets: [
                    BuildRequest.BuildTargetInfo(parameters: parameters, target: target),
                ],
                continueBuildingAfterErrors: true,
                useParallelTargets: true,
                useImplicitDependencies: false,
                useDryRun: false
            )
            try core.performInitialization(for: buildRequest)

            let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: localFS, processExecutionCache: .sharedForTesting)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let settings = Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target)

            #expect(settings.errors == [])
            #expect(settings.sdk?.canonicalName == sdkManifestPath.str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == tmpDir.join("WASI.sdk"))
        }
    }

    @Test(.requireSDKs(.host))
    func packageProductSwiftSDKRunDestinationUsesManifestSDKRoot() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await Self.makeCore()

            let sdkManifestContents = """
            {
                "schemaVersion" : "4.0",
                "targetTriples" : {
                    "wasm32-unknown-wasip1" : {
                        "sdkRootPath" : "WASI.sdk",
                        "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift_static",
                        "toolsetPaths" : [
                            "toolset.json"
                        ]
                    }
                }
            }
            """
            let sdkManifestPath = tmpDir.join("swift-sdk.json")
            try localFS.createDirectory(tmpDir)
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false) {
                $0.write(sdkManifestContents)
            }
            try await localFS.writeFileContents(tmpDir.join("toolset.json"), waitForNewTimestamp: false) { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0"
                }
                """)
            }

            let packageTestsName = "SDKRootAutoReproPackageTests"
            let workspace = try TestWorkspace("Workspace", projects: [
                TestPackageProject(
                    "SDKRootAutoRepro",
                    sourceRoot: tmpDir.join("Package"),
                    groupTree: TestGroup("Package", children: [
                        TestFile("SDKRootAutoReproTests.swift"),
                    ]),
                    targets: [
                        TestPackageProductTarget(
                            packageTestsName,
                            frameworksBuildPhase: TestFrameworksBuildPhase([
                                TestBuildFile(.target("SDKRootAutoReproTests")),
                            ]),
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "SDKROOT": "auto",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ]),
                            ],
                            dependencies: ["SDKRootAutoReproTests"]
                        ),
                        TestStandardTarget(
                            "SDKRootAutoReproTests",
                            type: .objectFile,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SDKROOT": "auto",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["SDKRootAutoReproTests.swift"]),
                            ]
                        ),
                    ]
                )
            ]).load(core)

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let requestParameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
            let targetParameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(
                parameters: requestParameters,
                buildTargets: [
                    BuildRequest.BuildTargetInfo(parameters: targetParameters, target: try #require(workspace.targets(named: packageTestsName).only)),
                ],
                continueBuildingAfterErrors: true,
                useParallelTargets: true,
                useImplicitDependencies: false,
                useDryRun: false
            )
            try core.performInitialization(for: buildRequest)

            let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: localFS, processExecutionCache: .sharedForTesting)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
            for targetName in [packageTestsName, "SDKRootAutoReproTests"] {
                let configuredTarget = try #require(buildGraph.allTargets.first { $0.target.name == targetName })
                #expect(configuredTarget.parameters.overrides["SDKROOT"] == sdkManifestPath.str, "\(targetName) should preserve the Swift SDK manifest path")
                #expect(configuredTarget.parameters.overrides["SDKROOT"] != "webassembly")

                let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
                #expect(settings.errors == [])
                #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == tmpDir.join("WASI.sdk"))
            }
        }
    }
}
