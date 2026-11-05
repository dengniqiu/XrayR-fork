# XrayR-fork

XrayR 安装与管理脚本，支持 systemd 和 Alpine/OpenRC。请使用 root 运行。

## 安装

Alpine 请先执行：`apk add --no-cache bash curl ca-certificates`

```bash
curl -fsSL https://raw.githubusercontent.com/dengniqiu/XrayR-fork/main/install.sh | bash -s -- install
```

安装后编辑 `/etc/XrayR/config.yml`，再执行 `XrayR start` 启动。
`XrayR` 打开管理菜单，`XrayR status` 查看状态，`XrayR log` 查看日志。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/dengniqiu/XrayR-fork/main/install.sh | bash -s -- uninstall
```

卸载会删除安装目录和配置目录。

## 低内存提示

512 MiB 及以下自动使用低内存安装模式。128 MiB 机器请将程序安装到真实磁盘，避免 tmpfs/ramfs；安装优化不保证运行时不会耗尽内存。
