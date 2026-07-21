#!/bin/sh
# ============================================================
# Alpine Linux nginx WebDAV 一键安装/卸载脚本
# 纯 sh 实现，不依赖任何 init 系统
# 用法:
#   安装: sh webdav-install.sh install [用户] [密码] [端口] [目录]
#   卸载: sh webdav-install.sh uninstall
# 示例:
#   sh webdav-install.sh install admin secret 8080 /mnt/data
# ============================================================

set -e

ACTION=${1:-install}
USER=${2:-admin}
PASS=${3:-$(openssl rand -base64 12)}
PORT=${4:-8080}
DATADIR=${5:-/var/webdav}
NGINX_CONF="/etc/nginx/nginx.conf"
PASSWD_FILE="/etc/nginx/.htpasswd"
SSL_DIR="/etc/nginx/ssl"
PID_FILE="/var/run/nginx.pid"
START_SCRIPT="/usr/local/bin/webdav-start.sh"
STOP_SCRIPT="/usr/local/bin/webdav-stop.sh"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# 检测端口是否被占用
check_port() {
    local port=$1
    # 尝试多种方式检测端口占用
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -q ":$port " && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -q ":$port " && return 0
    fi
    if command -v fuser >/dev/null 2>&1; then
        fuser "$port/tcp" >/dev/null 2>&1 && return 0
    fi
    # 尝试用 /proc/net/tcp 检测
    if [ -r /proc/net/tcp ]; then
        local hex_port
        hex_port=$(printf '%04X' "$port")
        grep -q ":${hex_port} " /proc/net/tcp && return 0
    fi
    return 1
}

# 杀掉占用端口的进程
kill_port() {
    local port=$1
    log_warn "端口 $port 被占用，尝试释放..."

    # 方式1: fuser
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "$port/tcp" >/dev/null 2>&1 && { sleep 1; return 0; }
    fi

    # 方式2: 从 /proc 查找
    if [ -d /proc ]; then
        for pid_dir in /proc/[0-9]*; do
            if [ -d "$pid_dir/fd" ]; then
                for fd in "$pid_dir"/fd/*; do
                    if [ -L "$fd" ]; then
                        local target
                        target=$(readlink "$fd" 2>/dev/null || true)
                        if echo "$target" | grep -q ":$port"; then
                            local pid
                            pid=$(basename "$pid_dir")
                            kill "$pid" 2>/dev/null || true
                        fi
                    fi
                done
            fi
        done
        sleep 1
    fi

    # 方式3: 尝试杀掉所有 nginx
    killall nginx 2>/dev/null || {
        for pid in $(ps | grep nginx | grep -v grep | awk '{print $1}'); do
            kill "$pid" 2>/dev/null || true
        done
    }
    sleep 1
}

# 停止 nginx
stop_nginx() {
    log_info "停止 nginx..."

    # 方式1: 用 PID 文件
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            # 强制终止
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # 方式2: killall
    killall nginx 2>/dev/null || true
    sleep 1

    # 方式3: ps + kill
    local pids
    pids=$(ps | grep nginx | grep -v grep | awk '{print $1}')
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi

    sleep 1
    rm -f "$PID_FILE"
    log_info "nginx 已停止"
}
start_nginx() {
    log_info "启动 nginx..."
    
    # 检查是否已在运行
    if ps | grep -q "nginx.*master"; then
        log_warn "nginx 已在运行，跳过启动"
        return 0
    fi
    
    # 检查端口占用
    if check_port "$PORT"; then
        log_warn "端口 $PORT 被占用，尝试释放..."
        kill_port "$PORT"
    fi
    
    # 再次检查
    if check_port "$PORT"; then
        log_error "端口 $PORT 仍被占用，无法启动"
        exit 1
    fi
    
    # 启动
    nginx
    
    # 验证
    sleep 1
    if [ -f /var/run/nginx.pid ] && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null; then
        log_info "nginx 启动成功 (PID: $(cat /var/run/nginx.pid))"
        return 0
    else
        log_error "nginx 启动失败"
        return 1
    fi
}

# 生成启动/停止脚本
generate_scripts() {
    # 启动脚本
    cat > "$START_SCRIPT" << 'SCRIPT'
#!/bin/sh
# WebDAV 启动脚本
PID_FILE="/var/run/nginx.pid"

# 停止现有进程
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || true)
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
    sleep 1
    [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
fi

killall nginx 2>/dev/null || true
sleep 1

for pid in $(ps | grep nginx | grep -v grep | awk '{print $1}'); do
    kill -9 "$pid" 2>/dev/null || true
done

sleep 1
rm -f "$PID_FILE"

# 启动
nginx

sleep 1
if [ -f /var/run/nginx.pid ] && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null; then
    echo "nginx 启动成功 (PID: $(cat /var/run/nginx.pid))"
    return 0
else
    echo "nginx 启动失败"
    return 1
fi
SCRIPT
    chmod +x "$START_SCRIPT"

    # 停止脚本
    cat > "$STOP_SCRIPT" << 'SCRIPT'
#!/bin/sh
# WebDAV 停止脚本
PID_FILE="/var/run/nginx.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || true)
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
    sleep 1
    [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
fi

killall nginx 2>/dev/null || true
sleep 1

for pid in $(ps | grep nginx | grep -v grep | awk '{print $1}'); do
    kill -9 "$pid" 2>/dev/null || true
done

rm -f "$PID_FILE"
echo "nginx 已停止"
SCRIPT
    chmod +x "$STOP_SCRIPT"
}

# 安装
install_webdav() {
    echo ""
    echo "========================================"
    echo "  nginx WebDAV 安装"
    echo "========================================"
    echo "  用户名:   $USER"
    echo "  密码:     $PASS"
    echo "  端口:     $PORT"
    echo "  数据目录: $DATADIR"
    echo "========================================"
    echo ""

    # 1. 安装依赖
    log_step "[1/8] 安装依赖..."
    apk add --no-cache nginx nginx-mod-http-dav-ext openssl 2>/dev/null || {
        log_warn "部分包可能已安装，继续..."
    }

    # 2. 创建目录
    log_step "[2/8] 创建数据目录..."
    mkdir -p "$DATADIR"
    mkdir -p /tmp/nginx_client_body
    mkdir -p /var/log/nginx
    mkdir -p "$SSL_DIR"
    chown -R nginx:nginx "$DATADIR" 2>/dev/null || chown -R root:root "$DATADIR" 2>/dev/null || true
    chown nginx:nginx /tmp/nginx_client_body 2>/dev/null || true
    chmod 755 "$DATADIR"

    # 3. 生成密码
    log_step "[3/8] 生成认证密码..."
    HASH=$(openssl passwd -apr1 "$PASS")
    echo "$USER:$HASH" > "$PASSWD_FILE"
    chown nginx:nginx "$PASSWD_FILE" 2>/dev/null || true
    chmod 640 "$PASSWD_FILE"

    # 4. 生成 SSL 证书
    log_step "[4/8] 生成自签名 SSL 证书..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/key.pem" \
        -out "$SSL_DIR/cert.pem" \
        -subj "/CN=localhost" 2>/dev/null || {
        log_warn "SSL 证书生成失败或已存在"
    }

    # 5. 查找 dav_ext 模块
    log_step "[5/8] 查找 WebDAV 扩展模块..."
    DAV_EXT_MODULE=$(find /usr/lib/nginx/modules/ -name "ngx_http_dav_ext_module.so" 2>/dev/null | head -n1)
    if [ -z "$DAV_EXT_MODULE" ]; then
        log_warn "未找到 dav_ext 模块，PROPFIND 可能受限"
        LOAD_MODULE=""
    else
        log_info "找到模块: $DAV_EXT_MODULE"
        LOAD_MODULE="load_module $DAV_EXT_MODULE;"
    fi

    # 6. 写入 nginx 配置
    log_step "[6/8] 写入 nginx 配置..."
    cat > "$NGINX_CONF" << EOF
$LOAD_MODULE

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    # HTTP WebDAV 服务器（带 CORS）
    server {
        listen $PORT;
        server_name localhost;

        root $DATADIR;

        location / {
            dav_methods PUT DELETE MKCOL COPY MOVE;
            dav_ext_methods PROPFIND OPTIONS;
            create_full_put_path on;
            client_body_temp_path /tmp/nginx_client_body;
            client_max_body_size 0;
            autoindex on;
            autoindex_exact_size off;
            autoindex_localtime on;
            auth_basic "WebDAV Auth";
            auth_basic_user_file $PASSWD_FILE;

            # CORS
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Depth, If-Match, If-Modified-Since, If-None-Match, If-Range, If-Unmodified-Since, Range' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range, ETag, Accept-Ranges' always;
            add_header 'Access-Control-Allow-Credentials' 'true' always;

            if (\$request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' '*';
                add_header 'Access-Control-Allow-Methods' 'GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND, OPTIONS';
                add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Depth';
                add_header 'Access-Control-Max-Age' 1728000;
                add_header 'Content-Length' 0;
                return 204;
            }
        }
    }

}
EOF

    # 7. 生成启动/停止脚本
    log_step "[7/8] 生成管理脚本..."
    generate_scripts

    # 8. 启动服务
    log_step "[8/8] 启动 nginx..."
    nginx -t || {
        log_error "nginx 配置测试失败"
        exit 1
    }

    start_nginx || {
        log_error "nginx 启动失败"
        exit 1
    }

    # 获取 IP
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' | head -n1 || echo "localhost")

    # 保存配置信息
    cat > /etc/webdav-info.txt << EOF
========================================
WebDAV 配置信息
========================================
HTTP:     http://$ip:$PORT
HTTPS:    https://$ip:443
用户名:   $USER
密码:     $PASS
数据目录: $DATADIR
========================================
管理命令:
  启动: $START_SCRIPT
  停止: $STOP_SCRIPT
========================================
EOF

    echo ""
    echo "========================================"
    cat /etc/webdav-info.txt
    echo "========================================"
    echo ""
    log_info "安装完成！"
    echo ""
    echo "测试命令:"
    echo "  curl -u $USER:$PASS -X PROPFIND http://localhost:$PORT/"
    echo "  curl -u $USER:$PASS -T /etc/hostname http://localhost:$PORT/test.txt"
    echo ""
}

# 卸载
uninstall_webdav() {
    echo ""
    echo "========================================"
    echo "  nginx WebDAV 卸载"
    echo "========================================"
    echo ""

    log_step "停止 nginx..."
    stop_nginx

    log_step "卸载软件包..."
    # apk del nginx nginx-mod-http-dav-ext 2>/dev/null || true

    log_step "清理文件..."
    rm -f "$NGINX_CONF"
    rm -f "$PASSWD_FILE"
    rm -f /etc/webdav-info.txt
    rm -f "$START_SCRIPT"
    rm -f "$STOP_SCRIPT"
    rm -rf "$SSL_DIR"
    rm -rf /tmp/nginx_client_body

    log_warn "数据目录保留: $DATADIR"
    log_warn "如需删除请手动执行: rm -rf $DATADIR"

    echo ""
    log_info "卸载完成！"
}

# 主逻辑
case "$ACTION" in
    install|i)
        install_webdav
        ;;
    uninstall|remove|u|r)
        uninstall_webdav
        ;;
    *)
        echo ""
        echo "用法:"
        echo "  安装: $0 install [用户] [密码] [端口] [目录]"
        echo "  卸载: $0 uninstall"
        echo ""
        echo "示例:"
        echo "  $0 install                    # 全部默认"
        echo "  $0 install admin secret       # 自定义账号密码"
        echo "  $0 install admin secret 8080  # 自定义端口"
        echo "  $0 install admin secret 8080 /mnt/data  # 全部自定义"
        echo "  $0 uninstall                  # 完全卸载"
        echo ""
        exit 1
        ;;
esac