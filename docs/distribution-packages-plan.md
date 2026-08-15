# Swiftix 发行版与官方软件包计划

> 状态：持续维护 · 最后核验：2026-08-15

## 1. 两层交付模型

SwiftixDistribution 同时服务两个不同生命周期，不能把它们混成一套启动逻辑：

| 层 | 格式 | 内容 | 交付时机 | 所有者 |
| --- | --- | --- | --- | --- |
| Base distribution | `.sximg` rootfs | 最小可启动用户空间、默认 `/etc`、预装的基础 `.pkg` | 随消费方发布；仅新 VM 首次启动恢复 | `Distribution/Minimal` |
| Optional software | `.pkg` | 用户显式选择的工具、数据和未来第三方 port | VM 运行后由 `pkg` 安装/升级 | 后续 `Packages/` / `Ports/` |

Base image 是“发行版模板”，不是每次 boot 的覆盖层。VM 一旦拥有持久化快照，快照就是该实例磁盘的事实来源；升级消费端或 base artifact 不得重新写入 `/usr/bin`、`/etc` 或用户修改过的文件。

`.pkg` 是统一的软件包格式：基础包可在构建时预装进 `.sximg`，其他包可在实例运行后独立升级和卸载。软件源服务可以验证、索引、存储和分发软件包，但不拥有源码，也不参与 base image 组装。

## 2. 已落地的 Minimal 发行版

`Swiftix Minimal 2.1.1` 由声明式 manifest 组装：

- 目标固定为 `GOOS=swiftix`、`GOARCH=svm64`；宿主可为 macOS 或 Linux；
- 17 个基础命令由 coreutils 仓库确定性构建为 `coreutils_1.0.0.pkg`，发行版按 manifest 校验包身份后安装；
- executable 安装到 `/usr/bin`，uid/gid 为 0、mode 为 `0755`；
- `/var/lib/pkg/status` 登记 `coreutils` 及其完整文件所有权，使后续升级和查询遵守同一套包管理语义；
- `/bin`、`/sbin`、`/lib` 使用 usr-merge symlink，并创建 Debian/FHS 常用目录；
- `/etc/hosts`、`/etc/os-release`、`/etc/pkg/sources.list` 作为发行版内容写入；
- rootfs 通过 `SwiftixImage` v1 编码，保留 inode metadata 与 link identity，并带 SHA-256 完整性摘要；
- checked-in artifact 由 `swift run SwiftixDistributionBuilder --check` 做 byte-for-byte 重建检查。

运行测试必须在真实 `Kernel + EventLoop` 中恢复 artifact，并从 `/usr/bin`/PATH 启动 executable image，而不只测试内部编译器函数。

## 3. 发行版版本与实例升级

发行版有独立版本，manifest 同时记录最低 Swiftix 版本。内容变化遵循以下规则：

1. 修改源码、静态文件、权限、symlink 或命令集合时提升发行版版本并重建 artifact。
2. CI 在 macOS/Linux 上分别构建，验证两端输出与 checked-in artifact 相同。
3. 每次发布记录 artifact digest；下游消费者在自己的发布流程中独立更新 pin 并验证恢复行为。
4. 新建 VM 使用新版 base；已有 VM 快照保持原状。
5. 对已有 VM 的系统迁移必须由显式、版本化、可回滚的升级机制完成，不能隐藏在消费端启动流程中。

当前 `.sximg` 摘要是完整性校验，不是发布签名。本地绑定交付由消费端发布链和 digest pin 共同约束；在线获取则必须先设计签名元数据、信任根、回滚保护和离线策略。

## 4. 可选官方软件策略

官方包优先补齐 base 与核心没有的能力，不为了“像 Linux”重复打包同名命令。候选程序必须由 Swiftix Go/runtime 真实承载，并明确小于 POSIX/GNU/上游的范围。

建议支持等级：

- **Base**：默认支持并进入发行版或基础元包，每次发布做行为测试；
- **Tools**：官方维护、用户按需安装；
- **Lab**：实验性 port，明确资源与兼容限制，不混入稳定 channel。

基础交付链已由 `coreutils` 打通，原计划中的 `tr`、`tac`、`paste`、`comm`、`fold`
已经进入基础包；第一批仓库可选包仍应先用 `hello-swiftix` 验证发布、在线安装、升级、卸载和回滚，然后再考虑：

```text
jsonq  netbench
```

`tree`、`file`、`hexdump`、`base64`、`sha256sum`、`date`、`tar`、`gzip` 等需要先补齐 binary-safe I/O、目录/时间 API 和对应标准库；不得用 UTF-8 文本实现冒充二进制工具。它们也应按 Debian 的包边界分别进入 `tree`、`file`、`util-linux`、`coreutils`、`tar`、`gzip`，而不是全部塞进 coreutils。`git`、`ssh`、完整 TLS `curl` 属于远期能力，必须经过系统调用、密码学、许可证、性能和长期维护评估。

## 5. `.pkg` 质量门槛

每个可选包进入官方 `main` 前必须满足：

1. 源码与第三方版本/digest 固定，构建不下载浮动依赖；
2. 两次构建的 `.pkg` bytes 完全一致；
3. archive manifest 与生成的 `Packages` 索引对包身份、文件名、大小和 digest 的记录一致；
4. 安装后的 executable 从真实 VFS PATH 启动；
5. 覆盖 fresh install、reinstall、upgrade、remove、冲突和失败回滚；
6. 网络测试使用可控虚拟拓扑和 logical time；
7. README、已知差异、exit status、LICENSE/NOTICE 和资源限制完整；
8. 先发布 staging，再把同一份 byte-identical archive 发布到 main。

当前默认 source 是：

```text
repo http://swiftix.holdon.work/repo ./
```

archive 会按索引 SHA-256 校验，但 HTTP 与未签名索引不足以抵抗同时替换索引和内容的攻击。正式可信发布前需要 signed index 或经过证书校验的 HTTPS transport。VM 启动不自动联网，仓库故障不能阻止开机或快照恢复。

## 6. 文件所有权原则

- base rootfs 可以拥有首次启动模板中的 `/etc`，但实例创建后由其持久化磁盘拥有；
- `.pkg` executable 安装到 `/usr/bin/<command>`，运行数据放 `/usr/share/<package>/`，文档和许可放 `/usr/share/doc/<package>/`；
- 没有 conffile merge 语义前，可选包不直接接管用户可能修改的 `/etc` 文件；
- 一个路径只有一个明确 owner，不使用启动代码覆盖包管理器或用户写入；
- 不安装到 `/home/user`，不运行任意 maintainer script，不发布外部平台二进制。

## 7. 后续里程碑

### M1：发行版发布工程化

- 为 `.sximg` 版本兼容与发布 digest 建立自动检查；
- 增加 release note、SBOM/源码对应关系和签名设计；
- 定义显式的 VM distribution upgrade/migration 接口。

### M2：可选包交付链

- 实现 `hello-swiftix` builder 与 staging E2E；
- 完成 signed index 或 HTTPS 信任方案；
- 发布首批文本/网络工具并验证真实升级。

### M3：系统工具能力

- 补 Swiftix Go 的 binary/file/time 能力；
- 发布二进制安全的基础工具和 opt-in `swiftix-tools` 元包；
- 建立第三方 Ports 的源码、patch、许可和资源基准流程。
