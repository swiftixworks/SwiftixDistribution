# SwiftixDistribution

SwiftixDistribution is the official build repository for Swiftix distributions. It owns the base system's static configuration, distribution manifests, and reproducible root filesystem artifacts. The [coreutils](https://github.com/swiftixworks/coreutils) repository owns the source code for the base commands and their native `.pkg` archive, while the [Swiftix](https://github.com/swiftixworks/Swiftix) repository defines the execution, package, and image formats. Downstream projects integrate a distribution through a versioned artifact.

```text
coreutils_1.0.0.pkg ─┐
                     ├──► Distribution/Minimal (/etc + manifest)
                     │                    │
                     │                    ▼
            SwiftixDistributionBuilder
                         │
                         ▼
       Artifacts/swiftix-minimal.sximg
                         │
                         ▼
       Downstream consumer verifies pinned digest
                         │
                         ▼
         New instance restores root filesystem
         Existing instance keeps its snapshot
```

`Swiftix Minimal 2.1.1` currently includes:

- 17 base commands installed and registered from the native `coreutils_1.0.0.pkg` archive: `cat`, `comm`, `echo`, `false`, `fold`, `head`, `nl`, `paste`, `rev`, `seq`, `sort`, `tac`, `tail`, `tr`, `true`, `uniq`, and `wc`;
- usr-merge-style `/bin`, `/sbin`, and `/lib` symbolic links, together with common Debian/FHS directories;
- `/etc/hosts`, `/etc/os-release`, and `/etc/pkg/sources.list`; and
- pinned distribution identity, version, and minimum Swiftix version metadata.

## Repository responsibilities

| Project | Responsibility |
| --- | --- |
| [Swiftix](https://github.com/swiftixworks/Swiftix) | Kernel and VFS, Go toolchain and runtime, the `SwiftixImage` codec, and `pkg` |
| [coreutils](https://github.com/swiftixworks/coreutils) | Go sources for the base commands, the deterministic package builder, and `coreutils_1.0.0.pkg` |
| **SwiftixDistribution** | Selection of base packages and `/etc` content, plus building, validating, and versioning root filesystem artifacts |
| Downstream consumers | Pinning and validating a specific `.sximg` version, and managing instance creation, persistence, and migration |

These boundaries keep command sources out of SwiftixDistribution and prevent them from being folded back into a Swiftix library target. Default `/etc` content remains part of the distribution. Consumer startup code must not create system files individually. Optional software is delivered through repositories configured for `pkg`, and instance startup does not depend on an online installation.

## Local builds

Building requires Swift 6.3 or later and the following sibling repository layout:

```text
swiftixworks/
├── Swiftix/
├── coreutils/
└── SwiftixDistribution/
```

The builder runs on macOS or Linux. Its output always targets `swiftix/svm64`.

```sh
swift run SwiftixDistributionBuilder
swift run SwiftixDistributionBuilder --check
swift test -Xswiftc -warnings-as-errors
```

The `--check` option rebuilds the image from the pinned coreutils package and the distribution inputs, then compares it byte for byte with the checked-in artifact. Use `--output <path>` to write an image to another location. A given package, manifest, and Swiftix toolchain must always produce identical bytes.

## Updating the distribution

1. Modify base commands in the coreutils repository, then rebuild and validate `Artifacts/coreutils_1.0.0.pkg`. Add static distribution files under `Distribution/Minimal/Root/`.
2. Update `Distribution/Minimal/manifest.json`. Package declarations must be unique and sorted by name, and every guest path must be a canonical absolute path.
3. Increment the distribution version in the manifest whenever the delivered content changes.
4. Run `swift run SwiftixDistributionBuilder` to rebuild `Artifacts/swiftix-minimal.sximg`.
5. Run the builder with `--check` and run the complete test suite. The tests verify image decoding, package status and file ownership, and command execution through the real `PATH`.
6. Publish the new artifact digest. Downstream consumers must update their pins explicitly and validate restoration as part of their own integration and release processes.

The digest appended to an `.sximg` detects corruption and supports exact pinning; it is not currently a release signature. When the artifact is bundled locally, downstream consumers should ship a specific version and verify its digest before restoration. Network delivery additionally requires an independent signature and trust model.

## Repository layout

```text
SwiftixDistribution/
├── Artifacts/swiftix-minimal.sximg
├── Distribution/Minimal/
│   ├── manifest.json
│   └── Root/etc/...
├── Sources/SwiftixDistributionBuilder/
├── Tests/SwiftixDistributionTests/
└── docs/distribution-packages-plan.md
```

See the [distribution and package plan](docs/distribution-packages-plan.md) for the proposed separation of optional first-party software and `.pkg` repositories.

## License

SwiftixDistribution is available under the [MIT License](LICENSE).
