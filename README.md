# SwiftixDistribution

Swiftix 的官方发行版构建仓库。这里拥有基础系统的静态配置、发行版清单和可复现的 root filesystem artifact；基础命令源码及其原生 `.pkg` 由 coreutils 仓库拥有，Swiftix 核心只定义执行、包和镜像格式，下游消费者通过版本化 artifact 集成发行版。

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
          下游消费者校验 pinned digest
                         │
                         ▼
              新实例恢复 root filesystem
              已有实例 snapshot 始终优先
```

当前 `Swiftix Minimal 2.1.1` 包含：

- 从原生 `coreutils_1.0.0.pkg` 安装并登记的 17 个基础命令：`cat`、`comm`、`echo`、`false`、`fold`、`head`、`nl`、`paste`、`rev`、`seq`、`sort`、`tac`、`tail`、`tr`、`true`、`uniq`、`wc`；
- usr-merge 风格的 `/bin`、`/sbin`、`/lib` 链接，以及 Debian/FHS 常用目录；
- `/etc/hosts`、`/etc/os-release` 和 `/etc/pkg/sources.list`；
- 固定的发行版身份、版本和最低 Swiftix 版本元数据。

## 项目边界

| 项目 | 职责 |
| --- | --- |
| [Swiftix](https://github.com/swiftixworks/Swiftix) | Kernel/VFS、Go 工具链与 runtime、`SwiftixImage` codec、`pkg` |
| [coreutils](https://github.com/swiftixworks/coreutils) | 基础命令 Go 源码、确定性构建器与 `coreutils_1.0.0.pkg` |
| **SwiftixDistribution** | 选择基础包和 `/etc` 内容，构建、验证并版本化 rootfs artifact |
| 下游消费者 | pin 并校验明确版本的 `.sximg`，管理实例创建、持久化和迁移 |

这条边界意味着：基础命令不由 SwiftixDistribution 复制源码，也不应重新放入 Swiftix library target；默认 `/etc` 仍属于发行版。消费端启动代码不逐项创建系统文件，可选软件通过 `pkg` 配置的软件源分发，实例启动不依赖在线安装。

## 本地构建

要求 Swift 6.3+，并保持以下同级目录布局：

```text
SwiftixGroup/
├── Swiftix/
├── coreutils/
└── SwiftixDistribution/
```

构建器可在 macOS 或 Linux 宿主运行，产物目标始终是 `swiftix/svm64`：

```bash
swift run SwiftixDistributionBuilder
swift run SwiftixDistributionBuilder --check
swift test -Xswiftc -warnings-as-errors
```

`--check` 会从 pinned coreutils `.pkg` 与发行版输入重新构建并逐字节比较 checked-in artifact。也可以用 `--output <path>` 生成到临时位置；相同包、清单和 Swiftix 工具链必须产生相同字节。

## 修改发行版

1. 基础命令在 coreutils 仓库修改，并先重建、验证 `Artifacts/coreutils_1.0.0.pkg`；静态文件放入 `Distribution/Minimal/Root/`。
2. 更新 `Distribution/Minimal/manifest.json`；package 声明必须唯一且按名称排序，所有 guest 路径必须是规范绝对路径。
3. 若交付内容变化，提升 manifest 中的发行版版本。
4. 运行 `swift run SwiftixDistributionBuilder` 重建 `Artifacts/swiftix-minimal.sximg`。
5. 运行 `--check` 和完整测试，确认 artifact 可解码、package status 与文件所有权正确、命令能通过真实 PATH 执行。
6. 发布新的 artifact digest；下游消费者在各自的集成与发布流程中显式更新 pin 并验证恢复行为。

`.sximg` 的尾部摘要用于损坏检测和精确 pinning，当前不是发行签名。本地绑定交付时，下游消费者应携带明确版本的 artifact 并在恢复前校验 digest；网络交付还需要独立的签名信任链。

## 目录

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

官方可选软件与 `.pkg` 仓库的后续分层见 [发行版与软件包计划](docs/distribution-packages-plan.md)。

## 许可证

本项目采用 [MIT License](LICENSE)。
