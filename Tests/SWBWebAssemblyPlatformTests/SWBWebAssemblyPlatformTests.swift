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
    func swiftPMCommonStaticLibraryUsesArchiveForSwiftSDKWasm() async throws {
        try await withTemporaryDirectory { tmpDir in
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyLibrary",
                        type: .commonStaticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SwiftFile.swift"),
                            ]),
                        ]),
                ])
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

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
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0"
                }
                """)
            })

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)
            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("Libtool"), .matchRuleItemBasename("libMyLibrary.a")) { _ in }
                results.checkNoTask(.matchTargetName("MyLibrary"), .matchRuleType("Ld"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func swiftSDKRunDestinationDoesNotRewriteAutomaticSDKRootToPlatformSDK() async throws {
        try await withTemporaryDirectory { tmpDir in
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestAggregateTarget(
                        "MyPackageTests",
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                   ]),
                        ],
                        dependencies: [
                            "MyLibrary",
                        ]),
                    TestStandardTarget(
                        "MyLibrary",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SwiftFile.swift"),
                            ]),
                        ]),
                ])
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

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
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0"
                }
                """)
            })

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            let workspaceContext = WorkspaceContext(core: core, workspace: tester.workspace, fs: localFS, processExecutionCache: .sharedForTesting)
            let project = tester.workspace.projects[0]
            let aggregateTarget = try #require(project.targets.first { $0.name == "MyPackageTests" })
            let buildRequest = BuildRequest(
                parameters: parameters,
                buildTargets: [
                    BuildRequest.BuildTargetInfo(parameters: parameters, target: aggregateTarget),
                ],
                dependencyScope: .workspace,
                continueBuildingAfterErrors: true,
                useParallelTargets: true,
                useImplicitDependencies: false,
                useDryRun: false
            )
            try core.performInitialization(for: buildRequest)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let settings = Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: aggregateTarget)
            #expect(settings.errors.isEmpty)
        }
    }

    @Test(.requireSDKs(.host))
    func swiftPMTestRunnerReportsExecutableArtifactForSwiftSDKWasm() async throws {
        try await withTemporaryDirectory { tmpDir in
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyPackageTests-product",
                        type: .swiftpmTestRunner,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "MyPackageTests",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(),
                        ]),
                ])
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

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
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "rootPath" : "swift.xctoolchain/usr/bin",
                    "schemaVersion" : "1.0"
                }
                """)
            })

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            let workspaceContext = WorkspaceContext(core: core, workspace: tester.workspace, fs: localFS, processExecutionCache: .sharedForTesting)
            let project = tester.workspace.projects[0]
            let testRunnerTarget = try #require(project.targets.first { $0.name == "MyPackageTests-product" })
            let buildRequest = BuildRequest(
                parameters: parameters,
                buildTargets: [
                    BuildRequest.BuildTargetInfo(parameters: parameters, target: testRunnerTarget),
                ],
                dependencyScope: .workspace,
                continueBuildingAfterErrors: true,
                useParallelTargets: true,
                useImplicitDependencies: false,
                useDryRun: false
            )
            try core.performInitialization(for: buildRequest)
            let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
            let settings = Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: testRunnerTarget)
            #expect(settings.errors.isEmpty)

            let artifactInfo = try #require(settings.productType?.artifactInfo(in: settings.globalScope))
            #expect(artifactInfo.kind == .executable)
            #expect(artifactInfo.path.str.hasSuffix("/MyPackageTests.wasm"))
        }
    }
}
