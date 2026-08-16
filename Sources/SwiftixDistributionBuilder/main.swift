/// Builds the deterministic Swiftix Minimal distribution image from native
/// Swiftix packages and static root-filesystem inputs. The builder runs only on
/// the host; deployed VMs consume the resulting `.sximg` artifact.

import Foundation
import Swiftix
import SwiftixImage
import SwiftixPackages

private struct DistributionManifest: Decodable {
    struct Package: Decodable {
        let name: String
        let version: String
        let repository: String
        let source: String
    }

    struct File: Decodable {
        let source: String
        let path: String
        let mode: String
    }

    struct Directory: Decodable {
        let path: String
        let mode: String
    }

    struct Symlink: Decodable {
        let path: String
        let target: String
    }

    let schemaVersion: Int
    let identifier: String
    let name: String
    let version: String
    let minimumSwiftixVersion: String
    let packages: [Package]
    let directories: [Directory]
    let files: [File]
    let symlinks: [Symlink]
}

private enum BuilderError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidManifest(String)
    case cannotCreateDirectory(String)
    case cannotWrite(String)
    case cannotSetMode(String)
    case cannotCreateSymlink(String)
    case staleArtifact(String)

    var description: String {
        switch self {
        case .invalidArgument(let message), .invalidManifest(let message):
            return message
        case .cannotCreateDirectory(let path):
            return "cannot create distribution directory \(path)"
        case .cannotWrite(let path):
            return "cannot write distribution file \(path)"
        case .cannotSetMode(let path):
            return "cannot set distribution mode on \(path)"
        case .cannotCreateSymlink(let path):
            return "cannot create distribution symlink \(path)"
        case .staleArtifact(let path):
            return "distribution image is stale; regenerate \(path)"
        }
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // SwiftixDistributionBuilder
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // repository root
private let workspaceRoot = repositoryRoot.deletingLastPathComponent()
private let distributionRoot =
    repositoryRoot
    .appendingPathComponent("Distribution/Minimal", isDirectory: true)
private let manifestURL = distributionRoot.appendingPathComponent("manifest.json")
private let defaultOutputURL =
    repositoryRoot
    .appendingPathComponent("Artifacts/swiftix-minimal.sximg")

private struct Arguments {
    let check: Bool
    let outputURL: URL

    init(_ raw: [String]) throws {
        var check = false
        var outputURL = defaultOutputURL
        var index = 0
        while index < raw.count {
            switch raw[index] {
            case "--check":
                check = true
            case "--output":
                index += 1
                guard index < raw.count else {
                    throw BuilderError.invalidArgument("--output requires a path")
                }
                outputURL =
                    URL(fileURLWithPath: raw[index], relativeTo: repositoryRoot)
                    .standardizedFileURL
            default:
                throw BuilderError.invalidArgument("unknown argument \(raw[index])")
            }
            index += 1
        }
        self.check = check
        self.outputURL = outputURL
    }
}

private func loadManifest() throws -> DistributionManifest {
    let manifest = try JSONDecoder().decode(
        DistributionManifest.self,
        from: Data(contentsOf: manifestURL))
    guard manifest.schemaVersion == 2 else {
        throw BuilderError.invalidManifest(
            "unsupported distribution manifest schema \(manifest.schemaVersion)")
    }
    let names = manifest.packages.map(\.name)
    guard names == names.sorted(), Set(names).count == names.count,
        names.allSatisfy(isSafeComponent),
        manifest.packages.allSatisfy({ isSafeComponent($0.repository) })
    else {
        throw BuilderError.invalidManifest(
            "distribution package names must be unique, safe, and sorted")
    }
    let directoryPaths = try manifest.directories.map { try validatedAbsolutePath($0.path) }
    let filePaths = try manifest.files.map { try validatedAbsolutePath($0.path) }
    let symlinkPaths = try manifest.symlinks.map { try validatedAbsolutePath($0.path) }
    let ownedPaths = directoryPaths + filePaths + symlinkPaths
    guard directoryPaths == directoryPaths.sorted(),
        filePaths == filePaths.sorted(),
        symlinkPaths == symlinkPaths.sorted(),
        Set(ownedPaths).count == ownedPaths.count
    else {
        throw BuilderError.invalidManifest(
            "distribution paths must be unique and sorted by section")
    }
    for package in manifest.packages {
        _ = try packageFileURL(package)
    }
    for directory in manifest.directories {
        _ = try parsedMode(directory.mode)
    }
    for file in manifest.files {
        _ = try sourceFileURL(file.source)
        _ = try parsedMode(file.mode)
    }
    guard
        manifest.symlinks.allSatisfy({
            !$0.target.isEmpty && !$0.target.contains("\0")
        })
    else {
        throw BuilderError.invalidManifest("invalid distribution symlink target")
    }
    return manifest
}

private func packageFileURL(_ declaration: DistributionManifest.Package) throws -> URL {
    let relativePath = declaration.source
    guard !relativePath.isEmpty,
        !relativePath.hasPrefix("/"),
        !relativePath.contains("\0")
    else {
        throw BuilderError.invalidManifest(
            "invalid package path \(relativePath)")
    }
    let packageRoot = workspaceRoot
        .appendingPathComponent(declaration.repository, isDirectory: true)
        .standardizedFileURL
    guard packageRoot.deletingLastPathComponent() == workspaceRoot.standardizedFileURL else {
        throw BuilderError.invalidManifest(
            "package repository escapes workspace: \(declaration.repository)")
    }
    let url = packageRoot.appendingPathComponent(relativePath)
        .standardizedFileURL
    guard url.path.hasPrefix(packageRoot.path + "/") else {
        throw BuilderError.invalidManifest(
            "package path escapes repository: \(relativePath)")
    }
    return url
}

private func loadPackage(
    _ declaration: DistributionManifest.Package
) throws -> PackageArchive {
    let bytes = Array(try Data(contentsOf: packageFileURL(declaration)))
    let archive = try PackageArchive.decode(bytes)
    guard archive.manifest.name == declaration.name,
        archive.manifest.version.description == declaration.version,
        archive.manifest.architecture == "svm64"
    else {
        throw BuilderError.invalidManifest(
            "package identity does not match declaration for \(declaration.name)")
    }
    return archive
}

private func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\0")
}

private func validatedAbsolutePath(_ path: String) throws -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard components.first?.isEmpty == true,
        components.count > 1,
        components.dropFirst().allSatisfy({ isSafeComponent(String($0)) }),
        !path.contains("\0")
    else {
        throw BuilderError.invalidManifest("invalid distribution path \(path)")
    }
    return path
}

private func sourceFileURL(_ relativePath: String) throws -> URL {
    guard !relativePath.isEmpty,
        !relativePath.hasPrefix("/"),
        !relativePath.contains("\0")
    else {
        throw BuilderError.invalidManifest(
            "invalid distribution source path \(relativePath)")
    }
    let url = distributionRoot.appendingPathComponent(relativePath)
        .standardizedFileURL
    guard url.path.hasPrefix(distributionRoot.path + "/") else {
        throw BuilderError.invalidManifest(
            "distribution source escapes root: \(relativePath)")
    }
    return url
}

private func parsedMode(_ text: String) throws -> FileMode {
    guard !text.isEmpty,
        text.allSatisfy({ ("0"..."7").contains($0) }),
        let raw = UInt16(text, radix: 8),
        raw <= 0o7777
    else {
        throw BuilderError.invalidManifest("invalid file mode \(text)")
    }
    return FileMode(rawValue: raw)
}

private func parentPath(_ path: String) -> String {
    var components = path.split(separator: "/")
    if !components.isEmpty { components.removeLast() }
    return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
}

private func createDirectoryTree(_ path: String, context: ProcessContext) throws {
    var current = ""
    for component in path.split(separator: "/") {
        current += "/" + component
        guard context.mkdir(current), context.lstat(current)?.type == .directory else {
            throw BuilderError.cannotCreateDirectory(current)
        }
    }
}

private func writeFile(
    path: String,
    bytes: [UInt8],
    mode: FileMode,
    context: ProcessContext
) throws {
    try createDirectoryTree(parentPath(path), context: context)
    guard let descriptor = context.open(path, create: true, truncate: true) else {
        throw BuilderError.cannotWrite(path)
    }
    let written = context.write(descriptor, bytes)
    context.close(descriptor)
    guard written == bytes.count else { throw BuilderError.cannotWrite(path) }
    guard context.chmod(path, mode: mode) else { throw BuilderError.cannotSetMode(path) }
    guard context.chown(path, uid: 0, gid: 0) else { throw BuilderError.cannotSetMode(path) }
}

private func buildImage(_ manifest: DistributionManifest) throws -> [UInt8] {
    let packages = try manifest.packages.map(loadPackage)
    var occupiedDirectories = Set(
        try manifest.directories.map { try validatedAbsolutePath($0.path) })
    var occupiedNonDirectories = Set(
        try manifest.files.map { try validatedAbsolutePath($0.path) }
            + manifest.symlinks.map { try validatedAbsolutePath($0.path) }
            + ["/var/lib/pkg/status"])
    for package in packages {
        for entry in package.entries {
            let accepted: Bool
            switch entry.kind {
            case .directory:
                accepted = !occupiedNonDirectories.contains(entry.path)
                occupiedDirectories.insert(entry.path)
            case .file:
                accepted = !occupiedDirectories.contains(entry.path)
                    && occupiedNonDirectories.insert(entry.path).inserted
            }
            guard accepted else {
                throw BuilderError.invalidManifest(
                    "multiple distribution inputs own \(entry.path)")
            }
        }
    }

    let loop = EventLoop()
    let kernel = Kernel(loop: loop)
    final class BuildState {
        var error: Error?
    }
    let state = BuildState()
    kernel.spawn("build-distribution") { context in
        do {
            for directory in manifest.directories.sorted(by: { $0.path < $1.path }) {
                let path = try validatedAbsolutePath(directory.path)
                try createDirectoryTree(path, context: context)
                guard context.chmod(path, mode: try parsedMode(directory.mode)) else {
                    throw BuilderError.cannotSetMode(path)
                }
                guard context.chown(path, uid: 0, gid: 0) else {
                    throw BuilderError.cannotSetMode(path)
                }
            }
            for file in manifest.files.sorted(by: { $0.path < $1.path }) {
                let path = try validatedAbsolutePath(file.path)
                let sourceURL = try sourceFileURL(file.source)
                try writeFile(
                    path: path,
                    bytes: Array(try Data(contentsOf: sourceURL)),
                    mode: try parsedMode(file.mode),
                    context: context)
            }
            var installed = InstalledDatabase()
            for package in packages {
                var ownedDirectories: [String] = []
                for entry in package.directories {
                    let existed = context.lstat(entry.path) != nil
                    try createDirectoryTree(entry.path, context: context)
                    if !existed {
                        guard context.chmod(entry.path, mode: FileMode(rawValue: entry.mode)),
                            context.chown(entry.path, uid: 0, gid: 0)
                        else {
                            throw BuilderError.cannotSetMode(entry.path)
                        }
                        ownedDirectories.append(entry.path)
                    }
                }
                for entry in package.files {
                    try writeFile(
                        path: entry.path,
                        bytes: package.contents(of: entry),
                        mode: FileMode(rawValue: entry.mode),
                        context: context)
                }
                installed.insert(
                    InstalledPackage(
                        manifest: package.manifest,
                        repository: "base",
                        files: package.files.map(\.path),
                        directories: ownedDirectories,
                        installedSize: package.installedSize,
                        automatic: false))
            }
            try writeFile(
                path: "/var/lib/pkg/status",
                bytes: Array(installed.rendered().utf8),
                mode: FileMode(rawValue: 0o644),
                context: context)
            for symlink in manifest.symlinks.sorted(by: { $0.path < $1.path }) {
                let path = try validatedAbsolutePath(symlink.path)
                try createDirectoryTree(parentPath(path), context: context)
                guard context.symlink(symlink.target, at: path) else {
                    throw BuilderError.cannotCreateSymlink(path)
                }
            }
        } catch {
            state.error = error
        }
        context.exit(state.error == nil ? 0 : 1)
    }
    loop.runUntilIdle()
    if let error = state.error { throw error }

    let image = SwiftixRootFilesystemImage(
        distribution: SwiftixDistributionMetadata(
            identifier: manifest.identifier,
            name: manifest.name,
            version: manifest.version,
            minimumSwiftixVersion: manifest.minimumSwiftixVersion),
        filesystem: kernel.snapshotFileSystem())
    return try SwiftixRootFilesystemImageCodec.encode(image)
}

do {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let bytes = try buildImage(loadManifest())
    _ = try SwiftixRootFilesystemImageCodec.decode(bytes)
    if arguments.check {
        let existing = try Data(contentsOf: arguments.outputURL)
        guard Array(existing) == bytes else {
            throw BuilderError.staleArtifact(arguments.outputURL.path)
        }
    } else {
        try FileManager.default.createDirectory(
            at: arguments.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(bytes).write(to: arguments.outputURL, options: .atomic)
    }
    let digest = try SwiftixRootFilesystemImageCodec.digest(of: bytes)
    print("\(arguments.check ? "verified" : "generated") \(arguments.outputURL.path)")
    print("sha256 \(digest)")
} catch {
    FileHandle.standardError.write(Data("SwiftixDistributionBuilder: \(error)\n".utf8))
    exit(1)
}
