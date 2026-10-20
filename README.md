# tcp-boost

Linux 服务器 TCP 加速脚本，启用 BBR + fq，并按带宽和延迟（BDP）计算 TCP 缓冲区。适合跨境 VPS、代理服务器（VLESS Reality、Trojan、Shadowsocks 等基于 TCP 的协议）。

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lukk4a/tcp-boost/main/tcp-boost.sh)
```

按默认值（1000Mbps、200ms）计算，执行前会显示计划并询问确认。带参数运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lukk4a/tcp-boost/main/tcp-boost.sh) -b 1000 -r 200
```

查看状态 / 卸载同理，在后面加 `status` 或 `uninstall`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Lukk4a/tcp-boost/main/tcp-boost.sh) uninstall
```

## 下载后运行

```bash
curl -fsSL https://raw.githubusercontent.com/Lukk4a/tcp-boost/main/tcp-boost.sh -o tcp-boost.sh

# 先预览要写入的配置（不做任何修改）
bash tcp-boost.sh -b 1000 -r 200 --dry-run

# 确认无误后执行
bash tcp-boost.sh -b 1000 -r 200 -y
```

- `-b`：服务器带宽，单位 Mbps（默认 1000）
- `-r`：从你的位置 ping 服务器的平均延迟，单位 ms（默认 200）

执行完后重启代理服务（如 `systemctl restart xray`），让新的文件句柄上限和 BBR 作用于所有连接。

## 命令

| 命令 | 说明 |
|---|---|
| `bash tcp-boost.sh [install] [选项]` | 应用优化（默认） |
| `bash tcp-boost.sh status` | 查看当前拥塞控制、qdisc、缓冲区、BBR 连接数 |
| `bash tcp-boost.sh uninstall` | 删除配置，并恢复安装前的运行参数 |

选项：`-b/--bandwidth`、`-r/--rtt`、`-y/--yes`（不询问）、`--dry-run`（只预览）、`-h/--help`。

## 做了什么

- **拥塞控制**：启用 BBR（内核支持时）和 fq，并当场重建出口网卡队列，无需重启
- **缓冲区**：按 2 × BDP（带宽 × 延迟）计算 TCP 缓冲上限，再按内存档位封顶（512MB 内存最多 8MB，16GB 以上最多 128MB）
- **TCP 行为**：关闭空闲后慢启动（`tcp_slow_start_after_idle=0`）、开启 TFO、MTU 探测、SACK、窗口缩放
- **连接队列**：提高 `somaxconn`、SYN 队列、网卡积压队列
- **TIME_WAIT / 端口**：开启 `tcp_tw_reuse`，缩短 FIN 超时，扩大本地端口范围
- **Keepalive**：更快发现并清理死连接
- **文件句柄**：提高 `fs.file-max` 和 `nofile`（limits.d + systemd）

## 安全设计

- 执行前确认，支持 `--dry-run` 预览
- 只写入自己的文件：`/etc/sysctl.d/99-zz-tcp-boost.conf`，不修改其他 sysctl 配置；发现同名参数时只提示
- 首次安装时把原始参数保存到 `/var/lib/tcp-boost/`，`uninstall` 可恢复
- 逐项读回验证参数是否生效
- 检测到容器环境（OpenVZ、LXC、Docker 等）时提示：这类环境的内核由宿主机控制，多数参数改不了
- 不调整 Swap

## 要求

- root 权限
- BBR 需要内核 ≥ 4.9
- 需要 KVM、Xen、VMware、物理机等能自己控制内核的环境

## License

[MIT](LICENSE)
