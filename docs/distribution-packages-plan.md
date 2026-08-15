# Swiftix Distribution and Official Package Plan

> Status: actively maintained · Last reviewed: 2026-08-15

## 1. Two-layer delivery model

SwiftixDistribution serves two distinct lifecycles. They must not be combined into a single startup path.

| Layer | Format | Contents | Delivery point | Owner |
| --- | --- | --- | --- | --- |
| Base distribution | `.sximg` root filesystem | Minimal bootable userland, default `/etc` content, and preinstalled base `.pkg` archives | Shipped with a consumer and restored only when a new VM starts for the first time | `Distribution/Minimal` |
| Optional software | `.pkg` | Explicitly selected tools and data, plus future third-party ports | Installed or upgraded by `pkg` after the VM is running | Future `Packages/` and `Ports/` repositories |

The base image is a distribution template, not an overlay applied at every boot. After a VM has a persistent snapshot, that snapshot is the source of truth for the instance's disk. Upgrading a consumer or its base artifact must not rewrite `/usr/bin`, `/etc`, or user-modified files.

The `.pkg` format is the common software package format. Base packages can be installed into an `.sximg` at build time, while other packages can be upgraded and removed independently after an instance starts. A package repository service may validate, index, store, and distribute packages, but it neither owns their source code nor participates in base image assembly.

## 2. Implemented Minimal distribution

`Swiftix Minimal 2.1.1` is assembled from a declarative manifest:

- The target is fixed at `GOOS=swiftix` and `GOARCH=svm64`; the host may be macOS or Linux.
- The coreutils repository deterministically builds 17 base commands into `coreutils_1.0.0.pkg`. The distribution validates the package identity declared by the manifest before installation.
- Executables are installed in `/usr/bin` with UID 0, GID 0, and mode `0755`.
- `/var/lib/pkg/status` records coreutils and its complete file ownership information so that subsequent queries and upgrades use the same package management semantics.
- `/bin`, `/sbin`, and `/lib` are usr-merge symbolic links, and the image contains common Debian/FHS directories.
- `/etc/hosts`, `/etc/os-release`, and `/etc/pkg/sources.list` are written as distribution-owned content.
- The root filesystem is encoded with `SwiftixImage` v1. The format preserves inode metadata and link identity and includes a SHA-256 integrity digest.
- `swift run SwiftixDistributionBuilder --check` verifies the checked-in artifact with a byte-for-byte rebuild.

Runtime tests must restore the artifact through a real `Kernel` and `EventLoop`, then launch executable images from `/usr/bin` through `PATH`. Testing internal compiler functions alone is insufficient.

## 3. Distribution versions and instance upgrades

The distribution has its own version, and its manifest also records the minimum compatible Swiftix version. Content changes follow these rules:

1. Increment the distribution version and rebuild the artifact when changing command sources, static files, permissions, symbolic links, or the command set.
2. Build on both macOS and Linux in CI, and verify that both outputs match the checked-in artifact.
3. Record the artifact digest for every release. Downstream consumers update their pins and validate restoration in their own release processes.
4. New VMs use the new base image; existing VM snapshots remain unchanged.
5. Migrations for existing VMs must use an explicit, versioned, and reversible upgrade mechanism. They must not be hidden in consumer startup code.

The current `.sximg` digest provides integrity checking, not release authentication. For locally bundled delivery, the consumer's release chain and digest pin jointly constrain the artifact. Network retrieval additionally requires signed metadata, a trust root, rollback protection, and a defined offline policy.

## 4. Optional official software

Official packages should add capabilities that are absent from the base distribution and Swiftix core. Packages should not duplicate commands merely to resemble Linux. Every candidate program must run on the actual Swiftix Go toolchain and runtime, and its documented scope must clearly distinguish it from POSIX, GNU, or upstream behavior.

Proposed support tiers:

- **Base:** Supported by default and included in the distribution or a base metapackage; behavior is tested for every release.
- **Tools:** Maintained by the project and installed by users as needed.
- **Lab:** Experimental ports with explicit resource and compatibility limits; never included in the stable channel.

Coreutils now establishes the base delivery pipeline. The originally planned `tr`, `tac`, `paste`, `comm`, and `fold` commands are part of the base package. Before publishing further optional packages, `hello-swiftix` should exercise publishing, online installation, upgrades, removal, and rollback. The next candidates are:

```text
jsonq  netbench
```

Programs such as `tree`, `file`, `hexdump`, `base64`, `sha256sum`, `date`, `tar`, and `gzip` require binary-safe I/O, directory and time APIs, and supporting standard libraries. Text-only UTF-8 implementations must not be presented as binary utilities. Package boundaries should also follow established Debian conventions: use separate `tree`, `file`, `util-linux`, `coreutils`, `tar`, and `gzip` packages instead of placing every command in coreutils. `git`, `ssh`, and a complete TLS-enabled `curl` are longer-term work and require evaluation of system calls, cryptography, licensing, performance, and ongoing maintenance.

## 5. `.pkg` quality requirements

Every optional package must satisfy these requirements before entering the official `main` repository:

1. Pin all source and third-party versions and digests. Builds must not download floating dependencies.
2. Two builds of the package must produce byte-identical `.pkg` archives.
3. The archive manifest and generated `Packages` index must agree on package identity, filename, size, and digest.
4. Installed executables must launch from the real VFS through `PATH`.
5. Tests must cover fresh installation, reinstallation, upgrade, removal, conflicts, and rollback after failure.
6. Network tests must use a controlled virtual topology and logical time.
7. Documentation must include a README, known behavioral differences, exit statuses, LICENSE or NOTICE files, and resource limits.
8. A package must be published to `staging` before the same byte-identical archive is promoted to `main`.

The current default source is:

```text
repo http://swiftix.holdon.work/repo ./
```

Package archives are checked against the SHA-256 digest in the index. However, HTTP and an unsigned index cannot prevent an attacker from replacing both the index and its contents. A trusted production release requires either a signed index or HTTPS with certificate validation. VM startup performs no automatic network access, so a repository outage cannot block boot or snapshot restoration.

## 6. File ownership rules

- The base root filesystem may own `/etc` in the first-boot template. After instance creation, the persistent instance disk owns that content.
- A `.pkg` installs executables in `/usr/bin/<command>`, runtime data in `/usr/share/<package>/`, and documentation and licenses in `/usr/share/doc/<package>/`.
- Until conffile merge semantics exist, optional packages must not take ownership of user-modifiable files in `/etc`.
- Every path has exactly one owner. Startup code must not overwrite files owned by the package manager or the user.
- Packages must not install files in `/home/user`, execute arbitrary maintainer scripts, or distribute binaries for external platforms.

## 7. Milestones

### M1: Distribution release engineering

- Add automated checks for `.sximg` version compatibility and release digests.
- Add release notes, an SBOM-to-source mapping, and a signature design.
- Define an explicit VM distribution upgrade and migration interface.

### M2: Optional package delivery

- Implement the `hello-swiftix` builder and a staging end-to-end test.
- Complete either a signed-index design or an HTTPS trust model.
- Publish the first text and network tools and validate real upgrades.

### M3: System utility support

- Add binary, file, and time capabilities to Swiftix Go.
- Publish binary-safe base utilities and an opt-in `swiftix-tools` metapackage.
- Establish source, patch, licensing, and resource-baseline processes for third-party ports.
