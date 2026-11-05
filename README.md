# XrayR-fork

Fork 自 XrayR。
本仓库提供二进制安装和管理脚本，不包含 XrayR 核心源码。

支持 Linux systemd 和 Alpine Linux OpenRC，需要 root 权限。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/dengniqiu/XrayR-fork/main/install.sh | bash -s -- install
```

Alpine 请先安装 Bash、curl 和 CA 证书，再执行上述安装命令：

```sh
apk add --no-cache bash curl ca-certificates
```

首次安装不会立即启动。编辑 `/etc/XrayR/config.yml` 中的面板信息后，使用
`XrayR start` 启动，`XrayR status` 查看状态，`XrayR log` 查看日志。
更新时保留配置，并恢复更新前正在运行的服务。

## 低内存安装

512 MiB 及以下（含容器 cgroup 内存限额）直接下载未压缩二进制。
所有大文件均暂存于安装目录所在文件系统，再通过同盘重命名安装，
不再将约 112 MiB 的二进制先放在 `/tmp` 再复制。失败时清理暂存文件；
更新替换失败时尝试恢复旧二进制和服务。

**128 MiB 机器必须使用真实磁盘存放程序。** `/tmp`、Alpine diskless 根目录
可能是 tmpfs/ramfs，文件本身就占内存。脚本会在低内存安装目标为
tmpfs、ramfs 或 rootfs 时提前停止，而不是继续下载导致系统失联。
先检查目标文件系统：

```sh
mkdir -p /usr/local/XrayR
df -PT /tmp /usr/local/XrayR
```

如果默认目录也是内存盘，先挂载真实磁盘，再选择其子目录，例如：

```bash
# 前提：/mnt/disk 已挂载到真实磁盘，且有足够空间。
curl -fsSL https://raw.githubusercontent.com/dengniqiu/XrayR-fork/main/install.sh -o /root/xrayr-install.sh
XRAYR_INSTALL_DIR=/mnt/disk/XrayR bash /root/xrayr-install.sh install
```

自定义安装目录、配置目录和仓库保存在 `/etc/XrayR-manager.conf`，后续管理
和卸载命令会读取它；环境变量仍可覆盖。目录使用不含空格的绝对路径。
升级期间磁盘还需要容纳新旧两个二进制，成功后自动删除旧版本。

低内存首次安装会创建 `${XRAYR_CONFIG_DIR:-/etc/XrayR}/runtime.env`，
将 `GOMEMLIMIT` 设置为内存限额的一半、`GOGC=50`；128 MiB 环境对应
`GOMEMLIMIT=64MiB`。此文件可自行调整，升级不覆盖。
`GOMEMLIMIT` 需要二进制使用 Go 1.19 或更高版本构建，且只是 Go 运行时
的软限制，不包含全部进程内存，不能保证 XrayR 在 128 MiB 下稳定运行。
若文件系统是 overlay，还需检查其 upperdir 是否实际位于内存盘。

Alpine/OpenRC 的进程日志位于 `/var/log/XrayR.log`，systemd 使用 journal。
Alpine 不运行菜单中的第三方 BBR 内核安装脚本。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/dengniqiu/XrayR-fork/main/install.sh | bash -s -- uninstall
```

卸载会删除当前安装目录和配置目录；已有配置备份、日志保留。

## 测试

在安装有 Bash、静态 BusyBox 和 Python 3 的 Linux 环境中以 root 运行：

```sh
python3 -m unittest discover -s tests -v
```

测试使用独立临时 chroot，模拟下载及 systemd/OpenRC 命令，不修改宿主服务。
覆盖低内存暂存、内存盘拒绝、cgroup 限额、配置保留、更新回退和管理命令。
