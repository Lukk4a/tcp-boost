#!/usr/bin/env bash
# ==============================================================================
# tcp-boost.sh — Linux 服务器 TCP 加速脚本
#
# 功能：
#   - 启用 BBR + fq，并立即作用于当前出口网卡（无需重启）
#   - 按 BDP（带宽 × 延迟）计算 TCP 缓冲区，再按内存档位封顶
#   - 连接队列 / TIME_WAIT / Keepalive / TFO 等常用参数调优
#   - 提高文件句柄上限（sysctl + limits + systemd）
#   - 首次安装时快照原始运行值，uninstall 可真正回滚运行状态
#   - 逐项读回验证，提示被其他配置文件覆盖的参数
#
# 用法：
#   bash tcp-boost.sh [install] [-b 带宽Mbps] [-r 延迟ms] [-y] [--dry-run]
#   bash tcp-boost.sh status
#   bash tcp-boost.sh uninstall
# ==============================================================================

set -Eeuo pipefail

VERSION="1.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/Lukk4a/tcp-boost/main/tcp-boost.sh"

# 通过 bash <(curl ...) 运行时 $0 是 /dev/fd/N，提示命令改用一键命令
case "$0" in
    /dev/fd/*|/proc/self/fd/*) SELF="bash <(curl -fsSL $SCRIPT_URL)" ;;
    *)                         SELF="bash $0" ;;
esac

CONF_FILE="/etc/sysctl.d/99-zz-tcp-boost.conf"   # zz：排在 99-sysctl.conf 之后加载
STATE_DIR="/var/lib/tcp-boost"
SNAPSHOT="$STATE_DIR/original.sysctl"
LIMITS_FILE="/etc/security/limits.d/99-tcp-boost.conf"
SYSTEMD_DROPIN="/etc/systemd/system.conf.d/99-tcp-boost.conf"

BANDWIDTH_MBPS=1000   # 默认按 1Gbps
RTT_MS=200            # 默认按 200ms（跨境线路典型值）
ASSUME_YES=false
DRY_RUN=false

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  %b✔%b %s\n' "$GREEN" "$NC" "$*"; }
warn()    { printf '  %b⚠%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()     { printf '  %b✗%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
section() { printf '\n%b%s%b\n' "$BOLD" "$*" "$NC"; }

trap 'die "第 $LINENO 行执行失败：$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行。"; }

sysctl_supported() { [[ -w "/proc/sys/${1//./\/}" ]]; }

# 规范化空白，便于比较 "4096 87380 6291456" 这类多值参数
norm() { awk '{$1=$1; print}' <<< "$1"; }

human() { awk -v b="$1" 'BEGIN{ if (b>=1048576) printf "%.0f MiB", b/1048576; else printf "%.0f KiB", b/1024 }'; }

default_iface() { ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# ------------------------------------------------------------------------------
# 环境检测
# ------------------------------------------------------------------------------
detect_env() {
    MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    KERNEL=$(uname -r)
    VIRT=$(systemd-detect-virt 2>/dev/null || true)
    VIRT=${VIRT:-unknown}
    IFACE=$(default_iface || true)

    case "$VIRT" in
        openvz|lxc|lxc-libvirt|docker|podman|wsl|systemd-nspawn)
            warn "检测到容器环境（$VIRT）：内核由宿主机控制，BBR 和大部分 sysctl 可能无法修改。" ;;
    esac

    modprobe tcp_bbr >/dev/null 2>&1 || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR=true
    else
        BBR=false
        warn "内核 $KERNEL 不支持 BBR（需要 ≥ 4.9 且编译了 tcp_bbr），将跳过拥塞控制设置。"
    fi
}

# ------------------------------------------------------------------------------
# 参数计算
# ------------------------------------------------------------------------------
calc_params() {
    # 内存档位：限制单连接缓冲上限，防止小内存机器被大窗口拖垮
    local cap
    if   (( MEM_MB <= 512 ));  then TIER="≤512MB";   cap=$((8   << 20)); SOMAXCONN=4096;  FILE_MAX=262144
    elif (( MEM_MB <= 1024 )); then TIER="≤1GB";     cap=$((16  << 20)); SOMAXCONN=8192;  FILE_MAX=524288
    elif (( MEM_MB <= 4096 )); then TIER="≤4GB";     cap=$((32  << 20)); SOMAXCONN=16384; FILE_MAX=1048576
    elif (( MEM_MB <= 16384 ));then TIER="≤16GB";    cap=$((64  << 20)); SOMAXCONN=32768; FILE_MAX=2097152
    else                            TIER=">16GB";    cap=$((128 << 20)); SOMAXCONN=65535; FILE_MAX=4194304
    fi

    # BDP = 带宽(B/s) × RTT(s)；缓冲区取 2×BDP 以容纳内核开销与突发
    BDP=$(( BANDWIDTH_MBPS * 1000000 / 8 * RTT_MS / 1000 ))
    local want=$(( BDP * 2 ))
    want=$(( (want + (1 << 20) - 1) >> 20 << 20 ))   # 向上取整到 MiB
    (( want < (4 << 20) )) && want=$((4 << 20))
    (( want > cap )) && want=$cap
    BUF_MAX=$want
    BACKLOG=$(( SOMAXCONN > 16384 ? SOMAXCONN : 16384 ))
}

# 输出 "key=value" 列表；不支持的键会在写入时跳过
build_params() {
    PARAMS=()
    P() { PARAMS+=("$1=$2"); }

    # 拥塞控制与队列
    P net.core.default_qdisc fq
    $BBR && P net.ipv4.tcp_congestion_control bbr

    # 缓冲区
    P net.core.rmem_max "$BUF_MAX"
    P net.core.wmem_max "$BUF_MAX"
    P net.core.rmem_default 262144
    P net.core.wmem_default 262144
    P net.ipv4.tcp_rmem "4096 131072 $BUF_MAX"
    P net.ipv4.tcp_wmem "4096 65536 $BUF_MAX"
    P net.ipv4.udp_rmem_min 16384
    P net.ipv4.udp_wmem_min 16384
    P net.ipv4.tcp_notsent_lowat 131072        # 减少发送队列堆积，降低延迟

    # TCP 行为
    P net.ipv4.tcp_window_scaling 1
    P net.ipv4.tcp_sack 1
    P net.ipv4.tcp_timestamps 1
    P net.ipv4.tcp_slow_start_after_idle 0     # 空闲后不重新慢启动，长连接提速明显
    P net.ipv4.tcp_no_metrics_save 1           # 不沿用历史连接的拥塞参数
    P net.ipv4.tcp_mtu_probing 1               # 应对 PMTU 黑洞
    P net.ipv4.tcp_fastopen 3                  # 客户端+服务端 TFO
    P net.ipv4.tcp_ecn 2                       # 被动接受 ECN，不主动发起

    # 连接队列
    P net.core.somaxconn "$SOMAXCONN"
    P net.core.netdev_max_backlog "$BACKLOG"
    P net.ipv4.tcp_max_syn_backlog "$SOMAXCONN"
    P net.ipv4.tcp_syncookies 1
    P net.ipv4.tcp_synack_retries 2
    P net.ipv4.tcp_syn_retries 3

    # TIME_WAIT / 端口
    P net.ipv4.tcp_tw_reuse 1
    P net.ipv4.tcp_fin_timeout 15
    P net.ipv4.tcp_max_tw_buckets 262144
    P net.ipv4.ip_local_port_range "10240 65535"

    # Keepalive：更快发现死连接
    P net.ipv4.tcp_keepalive_time 300
    P net.ipv4.tcp_keepalive_intvl 30
    P net.ipv4.tcp_keepalive_probes 3

    # 文件句柄（不降低已有更高值）
    local cur
    cur=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
    if [[ ${#cur} -gt ${#FILE_MAX} || ( ${#cur} -eq ${#FILE_MAX} && "$cur" > "$FILE_MAX" ) ]]; then
        P fs.file-max "$cur"
    else
        P fs.file-max "$FILE_MAX"
    fi
    P fs.nr_open 1048576
}

# ------------------------------------------------------------------------------
# 安装
# ------------------------------------------------------------------------------
show_plan() {
    section "环境"
    info "内核：$KERNEL    虚拟化：$VIRT    出口网卡：${IFACE:-未知}"
    info "内存：${MEM_MB}MB（档位 $TIER）    CPU：${CPU_CORES} 核"
    info "当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)    当前 qdisc：$(sysctl -n net.core.default_qdisc 2>/dev/null)"

    section "计划"
    info "按 ${BANDWIDTH_MBPS}Mbps × ${RTT_MS}ms 计算 BDP = $(human "$BDP")，TCP 缓冲上限 = $(human "$BUF_MAX")"
    info "拥塞控制：$($BBR && echo bbr || echo 不修改)    队列：fq"
    info "somaxconn：$SOMAXCONN    文件句柄：$FILE_MAX"
}

confirm() {
    $ASSUME_YES && return 0
    [[ -t 0 ]] || die "非交互环境请加 -y 确认执行。"
    local ans
    read -r -p "  确认应用以上配置？[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; exit 0; }
}

write_conf() {
    local tmp kv key val
    tmp=$(mktemp)
    {
        echo "# Generated by tcp-boost.sh $VERSION at $(date '+%F %T')"
        echo "# ${MEM_MB}MB RAM / ${CPU_CORES} CPU / ${BANDWIDTH_MBPS}Mbps x ${RTT_MS}ms"
        for kv in "${PARAMS[@]}"; do
            key=${kv%%=*}; val=${kv#*=}
            if sysctl_supported "$key"; then echo "$key = $val"; fi
        done
    } > "$tmp"

    if $DRY_RUN; then
        section "将写入 $CONF_FILE（dry-run）"
        sed 's/^/    /' "$tmp"
        rm -f "$tmp"
        return
    fi

    # 首次安装时快照原始运行值，供 uninstall 回滚
    if [[ ! -f "$SNAPSHOT" ]]; then
        mkdir -p "$STATE_DIR"
        for kv in "${PARAMS[@]}"; do
            key=${kv%%=*}
            sysctl_supported "$key" && printf '%s = %s\n' "$key" "$(sysctl -n "$key")"
        done > "$SNAPSHOT"
        ok "已保存原始参数快照：$SNAPSHOT"
    fi

    install -m 644 "$tmp" "$CONF_FILE"
    rm -f "$tmp"
    ok "已写入 $CONF_FILE"
}

write_limits() {
    $DRY_RUN && return
    cat > "$LIMITS_FILE" <<'EOF'
# Generated by tcp-boost.sh
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    if [[ -d /run/systemd/system ]]; then
        mkdir -p "$(dirname "$SYSTEMD_DROPIN")"
        printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > "$SYSTEMD_DROPIN"
        systemctl daemon-reexec >/dev/null 2>&1 || true
    fi
    ok "文件句柄上限已提高（新登录会话 / 重启后的服务生效）"
}

# default_qdisc 只对新建的 qdisc 生效；删除根 qdisc 让内核按新默认值重建（会有毫秒级抖动）
apply_qdisc_now() {
    $DRY_RUN && return
    [[ -n "${IFACE:-}" ]] && command -v tc >/dev/null 2>&1 || return 0
    if tc qdisc show dev "$IFACE" | grep -qw fq; then
        ok "$IFACE 已在使用 fq"
        return
    fi
    if tc qdisc del dev "$IFACE" root 2>/dev/null && tc qdisc show dev "$IFACE" | grep -qw fq; then
        ok "$IFACE 已切换到 fq"
    else
        warn "$IFACE 未能立即切换 fq（虚拟网卡常见），重启后生效；BBR 在 4.13+ 内核不依赖 fq 也可工作。"
    fi
}

verify() {
    section "验证"
    local kv key want got bad=0
    for kv in "${PARAMS[@]}"; do
        key=${kv%%=*}; want=${kv#*=}
        sysctl_supported "$key" || continue
        got=$(sysctl -n "$key" 2>/dev/null || echo "?")
        if [[ "$(norm "$got")" != "$(norm "$want")" ]]; then
            warn "$key 目标 [$want] 实际 [$got]"
            bad=$((bad + 1))
        fi
    done
    (( bad == 0 )) && ok "全部参数已生效"

    # 列出其他会覆盖本配置的同名设置（加载顺序在本文件之后，或 /etc/sysctl.conf）
    local f k found=0
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf; do
        [[ -f "$f" && "$f" != "$CONF_FILE" ]] || continue
        for kv in "${PARAMS[@]}"; do
            k=${kv%%=*}
            if grep -Eq "^[[:space:]]*-?${k//./[./]}[[:space:]]*=" "$f"; then
                (( found++ == 0 )) && warn "以下文件也设置了相同参数，可能互相覆盖，建议手动清理："
                info "    $f: $k"
            fi
        done
    done

    info "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)    默认 qdisc：$(sysctl -n net.core.default_qdisc)"
    return 0
}

do_install() {
    require_root
    detect_env
    calc_params
    build_params
    show_plan
    $DRY_RUN || confirm
    section "应用"
    write_conf
    if ! $DRY_RUN; then
        sysctl -p "$CONF_FILE" >/dev/null 2>&1 || warn "部分参数加载失败，见下方验证结果。"
        apply_qdisc_now
        write_limits
        verify
        section "完成"
        info "查看状态：$SELF status"
        info "回滚：    $SELF uninstall"
    fi
}

# ------------------------------------------------------------------------------
# 状态 / 卸载
# ------------------------------------------------------------------------------
do_status() {
    local iface
    iface=$(default_iface || true)
    section "TCP 加速状态"
    info "配置文件：$([[ -f $CONF_FILE ]] && echo "$CONF_FILE" || echo 未安装)"
    info "可用拥塞控制：$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    info "当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    info "默认 qdisc：$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    [[ -n "$iface" ]] && command -v tc >/dev/null 2>&1 && \
        info "$iface qdisc：$(tc qdisc show dev "$iface" | awk '{print $2}' | sort -u | paste -sd, -)"
    info "TCP 缓冲上限：rmem=[$(sysctl -n net.ipv4.tcp_rmem)] wmem=[$(sysctl -n net.ipv4.tcp_wmem)]"
    if command -v ss >/dev/null 2>&1; then
        info "使用 BBR 的连接数：$(ss -tin 2>/dev/null | grep -c bbr || true)"
    fi
}

do_uninstall() {
    require_root
    section "卸载"
    rm -f "$CONF_FILE" "$LIMITS_FILE" "$SYSTEMD_DROPIN"
    ok "已删除配置文件"
    if [[ -f "$SNAPSHOT" ]]; then
        sysctl -p "$SNAPSHOT" >/dev/null 2>&1 || warn "部分原始参数恢复失败。"
        ok "已恢复安装前的运行参数"
        rm -rf "$STATE_DIR"
        local iface
        iface=$(default_iface || true)
        [[ -n "$iface" ]] && command -v tc >/dev/null 2>&1 && tc qdisc del dev "$iface" root 2>/dev/null || true
    else
        warn "未找到原始参数快照，仅删除了配置；运行值保持不变，重启后恢复系统默认。"
    fi
    [[ -d /run/systemd/system ]] && systemctl daemon-reexec >/dev/null 2>&1 || true
    # 让其他 sysctl 配置重新生效
    sysctl --system >/dev/null 2>&1 || true
    ok "卸载完成"
}

# ------------------------------------------------------------------------------
# 入口
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
tcp-boost $VERSION — Linux TCP 加速

用法：
  $SELF [install] [选项]   应用优化（默认）
  $SELF status             查看当前状态
  $SELF uninstall          删除配置并恢复安装前的运行参数

选项：
  -b, --bandwidth N     服务器带宽，单位 Mbps（默认 $BANDWIDTH_MBPS）
  -r, --rtt N           到主要用户的往返延迟，单位 ms（默认 $RTT_MS）
  -y, --yes             不询问直接执行
      --dry-run         只显示将写入的配置，不做修改
  -h, --help            显示帮助

示例：
  $SELF -b 500 -r 180 -y   500Mbps 带宽、180ms 延迟的跨境 VPS
EOF
}

main() {
    local cmd=install
    case "${1:-}" in
        install|status|uninstall) cmd=$1; shift ;;
        -h|--help) usage; exit 0 ;;
    esac
    while (( $# )); do
        case "$1" in
            -b|--bandwidth) BANDWIDTH_MBPS=${2:-}; shift 2 ;;
            -r|--rtt)       RTT_MS=${2:-}; shift 2 ;;
            -y|--yes)       ASSUME_YES=true; shift ;;
            --dry-run)      DRY_RUN=true; shift ;;
            -h|--help)      usage; exit 0 ;;
            *) usage >&2; die "未知参数：$1" ;;
        esac
    done
    [[ "$BANDWIDTH_MBPS" =~ ^[1-9][0-9]*$ ]] || die "带宽必须是正整数（Mbps）"
    [[ "$RTT_MS" =~ ^[1-9][0-9]*$ ]] || die "延迟必须是正整数（ms）"

    printf '%btcp-boost %s%b\n' "$BOLD" "$VERSION" "$NC"
    case "$cmd" in
        install)   do_install ;;
        status)    do_status ;;
        uninstall) do_uninstall ;;
    esac
}

main "$@"
