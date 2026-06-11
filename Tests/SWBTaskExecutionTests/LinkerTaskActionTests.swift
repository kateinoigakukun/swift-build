//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing

import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct LinkerTaskActionTests {
    @Test(.skipHostOS(.windows, "uses a shell script as a fake archiver"))
    func extractArchiveInputsPreservesDuplicateMemberNames() async throws {
        try await withTemporaryDirectory { tmpDir in
            let arPath = try writeFakeAr(in: tmpDir)
            let inputArchive = tmpDir.join("input.a")
            let outputArchive = tmpDir.join("output.a")
            let firstDir = tmpDir.join("first")
            let secondDir = tmpDir.join("second")
            let directDir = tmpDir.join("direct")
            try localFS.createDirectory(firstDir)
            try localFS.createDirectory(secondDir)
            try localFS.createDirectory(directDir)

            let firstObject = firstDir.join("same.o")
            let secondObject = secondDir.join("same.o")
            let directObject = directDir.join("direct.o")
            try localFS.write(firstObject, contents: ByteString(encodingAsUTF8: "first"))
            try localFS.write(secondObject, contents: ByteString(encodingAsUTF8: "second"))
            try localFS.write(directObject, contents: ByteString(encodingAsUTF8: "direct"))

            try await run(arPath, ["rcs", inputArchive.basename, "first/same.o", "second/same.o"], workingDirectory: tmpDir)
            #expect(try await archiveMembers(arPath, inputArchive) == ["same.o", "same.o"])

            let action = LinkerTaskAction(
                expandResponseFiles: true,
                responseFileFormat: .unixShellQuotedSpaceSeparated,
                extractArchiveInputs: true
            )
            let task = Task(
                forTarget: nil,
                ruleInfo: [],
                commandLine: [arPath, "rcs", outputArchive.str, directObject.str, inputArchive.str],
                workingDirectory: tmpDir,
                outputs: [MakePlannedPathNode(outputArchive)],
                action: action,
                execDescription: ""
            )

            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: MockExecutionDelegate(fs: localFS),
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: MockTaskOutputDelegate()
            )

            #expect(result == .succeeded)
            #expect(try await archiveMembers(arPath, outputArchive) == ["direct.o", "same.o", "same.o"])
        }
    }

    private func archiveMembers(_ arPath: String, _ archive: Path) async throws -> [String] {
        let result = try await Process.getOutput(
            url: URL(fileURLWithPath: arPath),
            arguments: ["t", archive.str]
        )
        return String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func run(_ toolPath: String, _ arguments: [String], workingDirectory: Path) async throws {
        let result = try await Process.getOutput(
            url: URL(fileURLWithPath: toolPath),
            arguments: arguments,
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory.str)
        )
        #expect(
            result.exitStatus.isSuccess,
            "Command failed: \(([toolPath] + arguments).joined(separator: " "))\n\(String(decoding: result.stderr, as: UTF8.self))"
        )
    }

    private func writeFakeAr(in tmpDir: Path) throws -> String {
        let arPath = tmpDir.join("fake-ar")
        try localFS.write(arPath, contents: ByteString(encodingAsUTF8: #"""
        #!/bin/sh
        set -eu

        command="$1"
        shift

        case "$command" in
            rcs)
                archive="$1"
                shift
                : > "$archive"
                for file in "$@"; do
                    printf '>>>%s\n' "$(basename "$file")" >> "$archive"
                    cat "$file" >> "$archive"
                    printf '\n<<<\n' >> "$archive"
                done
                ;;
            t)
                archive="$1"
                awk '/^>>>/ { sub(/^>>>/, ""); print }' "$archive"
                ;;
            x)
                archive="$1"
                awk '
                    /^>>>/ { if (out != "") close(out); out = substr($0, 4); next }
                    /^<<</ { if (out != "") close(out); out = ""; next }
                    out != "" { print > out }
                ' "$archive"
                ;;
            xN)
                instance="$1"
                archive="$2"
                member="$3"
                awk -v target="$member" -v targetInstance="$instance" '
                    /^>>>/ {
                        if (out != "") close(out)
                        current = substr($0, 4)
                        if (current == target) count += 1
                        out = (current == target && count == targetInstance) ? current : ""
                        next
                    }
                    /^<<</ { if (out != "") close(out); out = ""; next }
                    out != "" { print > out }
                ' "$archive"
                ;;
            *)
                echo "unsupported fake ar command: $command" >&2
                exit 1
                ;;
        esac
        """#))
        try localFS.setFilePermissions(arPath, permissions: 0o755)
        return arPath.str
    }
}
