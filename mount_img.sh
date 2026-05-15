#!/bin/bash
set -euo pipefail

# ========== 配置与颜色 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNT_BASE="${SCRIPT_DIR}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; DIM='\033[0;90m'; NC='\033[0m'

CLEANED_UP=0
SCRIPT_NAME="$(basename "$0")"
SKIP_BACKUP=0
BACKUP_DIR=""

# ========== 帮助信息 ==========
usage() {
    cat << EOF
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${CYAN}  ${SCRIPT_NAME}${NC}  —  IMG 镜像 losetup 挂载 / 急救工具
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${GREEN}用法:${NC}
  cd <img所在目录> && sudo ./${SCRIPT_NAME} [选项] [img文件]

${GREEN}选项:${NC}
  ${YELLOW}<无选项> <img>${NC}         正常模式：自动备份 → losetup -P → 挂载
  ${YELLOW}--no-backup${NC}              跳过备份（危险：修改直接落盘）
  ${YELLOW}--backup-dir <dir>${NC}       指定备份目录（默认与 img 同目录）
  ${YELLOW}--rescue <img>${NC}           精准急救：强制清理该 img 关联的所有 loop/挂载
  ${YELLOW}--rescue-all${NC}               全局急救：清理脚本目录下所有 img-mount 残留
  ${YELLOW}--status [img]${NC}             诊断模式：查看 loop 设备、挂载状态、占用进程
  ${YELLOW}--help${NC} / ${YELLOW}-h${NC}              显示本帮助文档

${GREEN}示例:${NC}
  ${DIM}# 在 img 所在目录执行（产生 ./boot 和 ./rootfs）${NC}
  cd ~/images && sudo ./${SCRIPT_NAME} 2026-05-09-15-51-b943ff.img

  ${DIM}# 跳过备份${NC}
  sudo ./${SCRIPT_NAME} --no-backup 2026-05-09-15-51-b943ff.img

  ${DIM}# 备份到指定目录${NC}
  sudo ./${SCRIPT_NAME} --backup-dir /backups 2026-05-09-15-51-b943ff.img

  ${DIM}# SSH 断开后的急救清理${NC}
  sudo ./${SCRIPT_NAME} --rescue 2026-05-09-15-51-b943ff.img

${GREEN}目录结构:${NC}
  脚本所在目录/
  ├── ${SCRIPT_NAME}
  ├── 2026-05-09-15-51-b943ff.img
  ├── 2026-05-09-15-51-b943ff.img.backup.20260516-012100
  ├── boot/          ← 挂载 p1 (FAT32)
  └── rootfs/        ← 挂载 p2 (ext4)
      ├── boot       ← 绑定挂载到 ../boot（可选）

${GREEN}技术说明:${NC}
  • 使用 losetup -P 自动扫描分区，生成 /dev/loopXp1 /dev/loopXp2
  • 修改直接落盘到 img，备份是最后的保险

${GREEN}安全机制:${NC}
  • 自动备份:   挂载前创建带时间戳的完整副本（--sparse=always）
  • 信号捕获:   EXIT/INT/TERM/HUP 异常退出自动 umount
  • 幂等清理:   --rescue / --rescue-all 可安全多次运行
  • 进程斩杀:   卸载前自动 kill 占用进程（SIGTERM → SIGKILL）

${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF
    exit 0
}

# ========== 备份函数 ==========
backup_img() {
    local img="$1"
    local img_dir img_name timestamp backup_path

    img_dir="$(dirname "$img")"
    img_name="$(basename "$img")"
    timestamp="$(date +%Y%m%d-%H%M%S)"

    if [[ -n "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        backup_path="${BACKUP_DIR}/${img_name}.backup.${timestamp}"
    else
        backup_path="${img_dir}/${img_name}.backup.${timestamp}"
    fi

    # 防止1秒内重复
    if [[ -f "$backup_path" ]]; then
        backup_path="${backup_path}.$(date +%N | cut -c1-3)"
    fi

    echo -e "${YELLOW}>>> 创建备份: ${backup_path}${NC}"
    if ! cp --sparse=always -p "$img" "$backup_path"; then
        echo -e "${RED}错误: 备份失败，中止操作${NC}" >&2
        exit 1
    fi

    local size
    size=$(du -h "$backup_path" | cut -f1)
    echo -e "${GREEN}  备份完成 (${size})${NC}"
    echo ""
}

# ========== 核心清理函数 ==========
cleanup_mounts() {
    local target_img="${1:-}"
    local aggressive="${2:-1}"
    
    [[ "$CLEANED_UP" -eq 1 ]] && return
    CLEANED_UP=1

    echo -e "\n${YELLOW}>>> 开始清理挂载残留...${NC}"

    # 1. 收集挂载点（脚本目录下的 boot 和 rootfs）
    local all_mounts=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local mp="$line"
        
        if [[ -n "$target_img" ]]; then
            local dev=""
            dev=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
            if [[ "$dev" == /dev/loop* ]]; then
                local loop_file=""
                loop_file=$(losetup -l -n -O BACK-FILE "$dev" 2>/dev/null || true)
                if [[ "$loop_file" != "$(realpath "$target_img" 2>/dev/null)" ]]; then
                    continue
                fi
            elif [[ "$mp" != "${SCRIPT_DIR}"* ]]; then
                continue
            fi
        fi
        all_mounts+=("$mp")
    done < <(mount | awk '{print $3}' | grep "^${SCRIPT_DIR}" | sort -r || true)

    # 2. 终止占用进程
    if [[ "$aggressive" -eq 1 ]]; then
        for mp in "${all_mounts[@]}"; do
            if mountpoint -q "$mp" 2>/dev/null; then
                local pids=""
                pids=$(lsof -t "$mp" 2>/dev/null || fuser -m "$mp" 2>/dev/null || true)
                if [[ -n "$pids" ]]; then
                    echo -e "${RED}  终止占用 ${mp} 的进程: ${pids}${NC}"
                    kill -TERM $pids 2>/dev/null || true
                    sleep 0.5
                    kill -KILL $pids 2>/dev/null || true
                fi
            fi
        done
    fi

    # 3. 逆序卸载绑定挂载点（rootfs 内部）
    local bind_points=(
        "${SCRIPT_DIR}/rootfs/boot"
        "${SCRIPT_DIR}/rootfs/dev/pts"
        "${SCRIPT_DIR}/rootfs/dev"
        "${SCRIPT_DIR}/rootfs/sys"
        "${SCRIPT_DIR}/rootfs/proc"
    )
    
    for bp in "${bind_points[@]}"; do
        [[ -e "$bp" ]] || continue
        if mountpoint -q "$bp" 2>/dev/null; then
            echo "  卸载绑定点 ${bp}"
            umount -R "$bp" 2>/dev/null || umount -f "$bp" 2>/dev/null || umount "$bp" 2>/dev/null || umount -l "$bp" 2>/dev/null || true
        fi
    done

    # 4. 卸载分区
    for sub in rootfs boot; do
        local mp="${SCRIPT_DIR}/${sub}"
        [[ -d "$mp" ]] || continue
        if mountpoint -q "$mp" 2>/dev/null; then
            echo "  卸载分区 ${mp}"
            umount -R "$mp" 2>/dev/null || umount -f "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        fi
    done

    # 5. 释放 loop 设备
    if [[ -n "$target_img" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local loop_dev loop_file
            loop_dev=$(echo "$line" | awk '{print $1}')
            loop_file=$(echo "$line" | awk '{print $3}')
            if [[ "$loop_file" == "$(realpath "$target_img")" ]]; then
                echo "  释放 loop 设备 ${loop_dev}"
                losetup -d "$loop_dev" 2>/dev/null || true
        sleep 0.3
            fi
        done < <(losetup -l -n | grep -F "$(realpath "$target_img")" || true)
    else
        echo "  扫描空闲 loop 设备..."
        for ld in /dev/loop*; do
            [[ -b "$ld" ]] || continue
            if ! mount | grep -q "^${ld} "; then
                losetup -d "$ld" 2>/dev/null || true
            fi
        done
    fi

    # 6. 清理空目录（只清理脚本目录下的 boot/rootfs）
    for sub in rootfs boot; do
        local dir="${SCRIPT_DIR}/${sub}"
        if [[ -d "$dir" ]]; then
            rmdir "$dir" 2>/dev/null || true
        fi
    done

    # 确保所有卸载操作同步到内核
    sync
    sleep 1  # 等待内核完成 lazy unmount 清理
    sleep 0.5

    echo -e "${GREEN}>>> 清理完成${NC}"
}

# ========== 诊断状态 ==========
show_status() {
    local target_img="${1:-}"
    
    echo -e "${CYAN}========== 挂载诊断 ==========${NC}"
    
    local found=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "  $line"
        found=1
    done < <(mount | grep "^${SCRIPT_DIR}" || true)
    
    if [[ "$found" -eq 0 ]]; then
        echo -e "${GREEN}  未发现 ${SCRIPT_DIR} 下的挂载点${NC}"
    fi

    echo ""
    echo -e "${CYAN}---------- Loop 设备 ----------${NC}"
    if [[ -n "$target_img" ]]; then
        losetup -l | grep -E "BACK-FILE|$(realpath "$target_img")" || echo "  无关联 loop 设备"
    else
        losetup -l 2>/dev/null || echo "  无 loop 设备"
    fi

    echo ""
    echo -e "${CYAN}---------- 占用进程 ----------${NC}"
    found=0
    for sub in rootfs boot; do
        local mp="${SCRIPT_DIR}/${sub}"
        [[ -d "$mp" ]] || continue
        local pids
        pids=$(lsof -t "$mp" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "  ${mp}: PID ${pids}"
            found=1
        fi
    done
    [[ "$found" -eq 0 ]] && echo "  无占用进程"

    echo ""
    echo -e "${CYAN}---------- 目录状态 ----------${NC}"
    for sub in rootfs boot; do
        local mp="${SCRIPT_DIR}/${sub}"
        if [[ -d "$mp" ]]; then
            if mountpoint -q "$mp" 2>/dev/null; then
                echo -e "  ${mp}: ${GREEN}已挂载${NC}"
            else
                echo -e "  ${mp}: ${YELLOW}目录存在但未挂载${NC}"
            fi
        else
            echo "  ${mp}: 不存在"
        fi
    done
}

# ========== 正常模式：备份 → losetup -P → 挂载 → 交互式 shell ==========
normal_mode() {
    local img="$1"
    local boot_mp="${SCRIPT_DIR}/boot"
    local root_mp="${SCRIPT_DIR}/rootfs"
    local loop_dev=""

    [[ $EUID -ne 0 ]] && { echo -e "${RED}错误: 请使用 sudo 或 root 身份运行${NC}"; exit 1; }
    [[ -f "$img" ]] || { echo -e "${RED}错误: 文件不存在: $img${NC}"; exit 1; }
    img="$(realpath "$img")"

    # 预检测残留
    # 预检测残留（使用 mount | grep 更可靠，mountpoint -q 在 lazy umount 后可能误判）
    local retry=0
    while [[ $retry -lt 3 ]]; do
        if mount | grep -qE "^${boot_mp}|^${root_mp}| on ${boot_mp} | on ${root_mp} "; then
            if [[ $retry -eq 0 ]]; then
                echo -e "${YELLOW}警告: 检测到挂载残留，尝试自动清理...${NC}"
                cleanup_mounts "" 1
                sleep 1
            else
                echo -e "${RED}错误: 挂载残留无法清理，请手动检查:${NC}"
                echo "  mount | grep ${SCRIPT_DIR}"
                exit 1
            fi
        else
            break
        fi
        ((retry++))
    done

    # 自动备份
    if [[ "$SKIP_BACKUP" -eq 0 ]]; then
        backup_img "$img"
    else
        echo -e "${YELLOW}>>> 已跳过备份（--no-backup）${NC}"
        echo ""
    fi

    mkdir -p "$boot_mp" "$root_mp"

    echo -e "${GREEN}>>> 镜像: ${img}${NC}"
    echo -e "${GREEN}>>> 工作目录: ${SCRIPT_DIR}${NC}"

    # ====== 核心：losetup -P 自动扫描分区 ======
    echo ">>> losetup -P 设置回环设备..."
    
    loop_dev=$(losetup -f --show -P "$img") || {
        echo -e "${RED}错误: losetup 失败，可能没有空闲 loop 设备${NC}" >&2
        echo "尝试运行: sudo $0 --rescue-all 释放残留"
        exit 1
    }

    echo -e "${GREEN}  回环设备: ${loop_dev}${NC}"
    echo "  分区扫描结果:"
    ls -l "${loop_dev}"* 2>/dev/null || true

    # 等待内核创建设备节点
    sleep 0.3
    if [[ ! -b "${loop_dev}p1" ]] || [[ ! -b "${loop_dev}p2" ]]; then
        echo -e "${YELLOW}  等待分区节点创建...${NC}"
        sleep 1
        partprobe "$loop_dev" 2>/dev/null || true
    fi

    # 挂载分区
    echo ">>> 挂载分区..."
    
    if [[ -b "${loop_dev}p1" ]]; then
        mount "${loop_dev}p1" "$boot_mp" || {
            echo -e "${RED}错误: 挂载 boot 分区 (${loop_dev}p1) 失败${NC}"
            losetup -d "$loop_dev" 2>/dev/null || true
            exit 1
        }
        echo -e "${GREEN}  ${loop_dev}p1 → ./boot${NC}"
    else
        echo -e "${RED}错误: 未找到 boot 分区设备 ${loop_dev}p1${NC}"
        losetup -d "$loop_dev" 2>/dev/null || true
        exit 1
    fi

    if [[ -b "${loop_dev}p2" ]]; then
        mount "${loop_dev}p2" "$root_mp" || {
            echo -e "${RED}错误: 挂载 rootfs 分区 (${loop_dev}p2) 失败${NC}"
            umount "$boot_mp" 2>/dev/null || true
            losetup -d "$loop_dev" 2>/dev/null || true
            exit 1
        }
        echo -e "${GREEN}  ${loop_dev}p2 → ./rootfs${NC}"
    else
        echo -e "${RED}错误: 未找到 rootfs 分区设备 ${loop_dev}p2${NC}"
        umount "$boot_mp" 2>/dev/null || true
        losetup -d "$loop_dev" 2>/dev/null || true
        exit 1
    fi

    # 注册 trap（异常退出时自动卸载）
    trap 'cleanup_mounts "" 1' EXIT INT TERM HUP

    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN}  镜像已挂载到: ${root_mp}${NC}"
    echo -e "${CYAN}  boot 分区: ./boot${NC}"
    echo -e "${CYAN}  rootfs 分区: ./rootfs${NC}"
    echo -e "${CYAN}  回环设备: ${loop_dev}${NC}"
    echo -e "${CYAN}=======================================${NC}"
    echo ""
    echo -e "${YELLOW}提示: 在此 shell 中可直接编辑 rootfs 内的文件${NC}"
    echo -e "${YELLOW}      输入 exit 退出并自动卸载${NC}"
    echo ""
    # 启动交互式 shell，工作目录在 rootfs 挂载点
    cd "$root_mp"
    /bin/bash --login || true
    cd "$SCRIPT_DIR"
}

# ========== 主入口 ==========
main() {
    local img_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --no-backup)
                SKIP_BACKUP=1
                shift
                ;;
            --backup-dir)
                [[ -z "${2:-}" ]] && { echo -e "${RED}错误: --backup-dir 需要指定目录${NC}"; exit 1; }
                BACKUP_DIR="$2"
                shift 2
                ;;
            --status)
                shift
                show_status "${1:-}"
                exit 0
                ;;
            --rescue)
                shift
                [[ -z "${1:-}" ]] && { echo -e "${RED}错误: --rescue 需要指定 img 文件${NC}"; usage; }
                [[ $EUID -ne 0 ]] && { echo -e "${RED}错误: 请使用 sudo${NC}"; exit 1; }
                cleanup_mounts "$(realpath "$1")" 1
                show_status "$1"
                exit 0
                ;;
            --rescue-all)
                [[ $EUID -ne 0 ]] && { echo -e "${RED}错误: 请使用 sudo${NC}"; exit 1; }
                cleanup_mounts "" 1
                show_status
                exit 0
                ;;
            -*)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                usage
                ;;
            *)
                img_file="$1"
                shift
                ;;
        esac
    done

    [[ -z "$img_file" ]] && usage
    normal_mode "$img_file"
}

main "$@"