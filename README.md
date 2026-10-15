# XrayR-fork

XrayR 的社区维护 fork，仓库地址：<https://github.com/dengniqiu/XrayR-fork>。

## 安装

使用 root 执行：

```bash
wget -N https://raw.githubusercontent.com/dengniqiu/XrayR-fork/main/install.sh
bash install.sh install
```

安装脚本会根据系统架构下载对应的 XrayR 二进制文件，并安装配置文件、管理脚本和 systemd 服务。

### 低内存机器

当系统总内存不超过 512 MiB 时，脚本会直接下载无压缩的 `XrayR-linux-*` 可执行文件，不调用 `unzip`，以降低解压阶段触发 OOM Killer 的风险。内存大于 512 MiB 时，使用 ZIP 发布包安装。

## 常用命令

```bash
XrayR start
XrayR stop
XrayR restart
XrayR status
```

默认配置文件：`/etc/XrayR/config.yml`

## 安装选项

可通过环境变量指定版本、仓库和安装目录：

```bash
XRAYR_VERSION=v1.0.0 bash install.sh install
XRAYR_REPO=dengniqiu/XrayR-fork bash install.sh install
XRAYR_INSTALL_DIR=/opt/XrayR XRAYR_CONFIG_DIR=/etc/XrayR bash install.sh install
```

## 卸载

```bash
bash install.sh uninstall
```
