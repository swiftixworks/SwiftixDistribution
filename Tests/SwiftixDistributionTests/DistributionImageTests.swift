/// End-to-end contract for the checked-in Swiftix Minimal image. Tests restore
/// the artifact through the public codec and execute its guest programs in the
/// real Swiftix kernel rather than reaching into builder internals.

import Foundation
import Swiftix
import SwiftixGoRuntime
import SwiftixImage
import SwiftixPackages
import Testing

@Suite("Swiftix Minimal distribution image")
struct DistributionImageTests {
    @Test("artifact carries distribution identity and canonical root filesystem")
    func artifactContents() throws {
        let image = try loadImage()
        #expect(image.distribution.identifier == "org.swiftix.minimal")
        #expect(image.distribution.version == "2.2.0")
        #expect(image.distribution.minimumSwiftixVersion == "0.11.0")
        #expect(image.distribution.operatingSystem == "swiftix")
        #expect(image.distribution.architecture == "svm64")

        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        #expect(kernel.restoreRootFilesystemImage(image))
        final class State {
            var binTarget: String?
            var libTarget: String?
            var sbinTarget: String?
            var osRelease = ""
            var repository = ""
            var packageStatus = ""
            var rootMode: FileMode?
            var tmpMode: FileMode?
            var executableNames: Set<String> = []
        }
        let state = State()
        kernel.spawn("inspect-distribution") { context in
            state.binTarget = context.readlink("/bin")
            state.libTarget = context.readlink("/lib")
            state.sbinTarget = context.readlink("/sbin")
            state.osRelease = readText("/etc/os-release", context: context)
            state.repository = readText("/etc/pkg/sources.list", context: context)
            state.packageStatus = readText("/var/lib/pkg/status", context: context)
            state.rootMode = context.stat("/root")?.mode
            state.tmpMode = context.stat("/tmp")?.mode
            for name in commandNames where context.canExecute("/usr/bin/" + name) {
                state.executableNames.insert(name)
            }
            context.exit(0)
        }
        loop.runUntilIdle()

        #expect(state.binTarget == "/usr/bin")
        #expect(state.libTarget == "/usr/lib")
        #expect(state.sbinTarget == "/usr/sbin")
        #expect(state.osRelease.contains("ID=swiftix"))
        #expect(state.osRelease.contains("ID_LIKE=debian"))
        #expect(state.repository.contains("repo http://swiftix.holdon.work/repo ./"))
        let installed = try InstalledDatabase.parse(state.packageStatus)
        #expect(installed.package(named: "coreutils")?.version.description == "1.0.0")
        #expect(installed.package(named: "sysutils")?.version.description == "0.1.0")
        #expect(installed.owner(ofFile: "/usr/bin/cat") == "coreutils")
        #expect(installed.owner(ofFile: "/usr/bin/memstat") == "sysutils")
        #expect(installed.owner(ofFile: "/usr/share/doc/coreutils/LICENSE") == "coreutils")
        #expect(installed.owner(ofFile: "/usr/share/doc/sysutils/README.md") == "sysutils")
        #expect(state.rootMode?.rawValue == 0o700)
        #expect(state.tmpMode?.rawValue == 0o1777)
        #expect(state.executableNames == Set(commandNames))
    }

    @Test("base commands execute through PATH from the restored image")
    func commandsExecute() throws {
        let loop = EventLoop()
        let kernel = Kernel(loop: loop)
        #expect(kernel.restoreRootFilesystemImage(try loadImage()))
        let terminal = PseudoTerminal()
        var output: [UInt8] = []
        terminal.onOutput = { [weak terminal] in
            guard let terminal else { return }
            output.append(contentsOf: terminal.readForApp(max: 65_535))
        }
        let commands = CommandRegistry.builtins
        GoExecutableLoader.register(in: commands)
        SwiftixPackages.register(in: commands)
        kernel.spawn("sh", Programs.shell(tty: terminal.slave, commands: commands))
        loop.runUntilIdle()
        for line in [
            "echo hello from distribution",
            "false",
            "echo false-status=$?",
            "seq 3 | cat",
            "echo banana | tr a-z A-Z",
            "echo abcdef | fold -w 3",
            "which echo",
            "memstat",
            "pstree",
            "pkg info coreutils",
            "pkg info sysutils",
            "pkg owner /usr/bin/cat",
            "pkg owner /usr/bin/memstat",
        ] {
            terminal.writeFromApp(Array((line + "\n").utf8))
            loop.runUntilIdle()
        }
        let rendered = String(decoding: output, as: UTF8.self)
        #expect(rendered.contains("hello from distribution\n"))
        #expect(rendered.contains("false-status=1"))
        #expect(rendered.contains("1\n2\n3\n"))
        #expect(rendered.contains("BANANA\n"))
        #expect(rendered.contains("abc\ndef\n"))
        #expect(rendered.contains("/usr/bin/echo"))
        #expect(rendered.contains("MODEL managed-runtime"))
        #expect(rendered.contains("sh("))
        #expect(rendered.contains("Package: coreutils"))
        #expect(rendered.contains("Package: sysutils"))
        #expect(rendered.contains("Status: installed"))
        #expect(rendered.contains("coreutils: /usr/bin/cat"))
        #expect(rendered.contains("sysutils: /usr/bin/memstat"))
    }

    @Test("instance snapshots override the immutable first-boot image")
    func instanceSnapshotWins() throws {
        let loop = EventLoop()
        let first = Kernel(loop: loop)
        let image = try loadImage()
        #expect(first.restoreRootFilesystemImage(image))
        first.spawn("customize") { context in
            let descriptor = context.open("/etc/local-machine", create: true)!
            context.write(descriptor, Array("instance state\n".utf8))
            context.close(descriptor)
            context.exit(0)
        }
        loop.runUntilIdle()
        let snapshot = first.snapshotFileSystem()

        let restored = Kernel(loop: loop)
        #expect(restored.restoreFileSystem(snapshot))
        #expect(restored.snapshotFileSystem() == snapshot)
        #expect(restored.snapshotFileSystem() != image.filesystem)
    }

    private var commandNames: [String] {
        [
            "cat", "comm", "echo", "false", "fold", "head", "nl", "paste",
            "rev", "seq", "sort", "tac", "tail", "tr", "true", "uniq", "wc",
            "lsof", "memstat", "pstree", "strace",
        ]
    }

    private func loadImage() throws -> SwiftixRootFilesystemImage {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Artifacts/swiftix-minimal.sximg")
        return try SwiftixRootFilesystemImageCodec.decode(
            Array(try Data(contentsOf: url)))
    }

    private func readText(_ path: String, context: ProcessContext) -> String {
        guard let descriptor = context.open(path) else { return "" }
        defer { context.close(descriptor) }
        return String(decoding: context.read(descriptor, max: 65_535), as: UTF8.self)
    }
}
