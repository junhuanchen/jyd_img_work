# 1. 先安装 QEMU（如果还没装）

sudo apt install qemu-user-static binfmt-support

# 2. 复制 qemu 到 rootfs

sudo mkdir -p /home/dls/jyd/rootfs/usr/bin
sudo cp /usr/bin/qemu-arm-static /home/dls/jyd/rootfs/usr/bin/

# 3. 用 sh 进入（Alpine 没有 bash）

sudo chroot /home/dls/jyd/rootfs /bin/sh

# 4. 进入后安装 bash（可选）

apk add bash

echo "nameserver 223.5.5.5" > /etc/resolv.conf

echo "nameserver 8.8.8.8" > /etc/resolv.conf

# 在 chroot 前，先准备 Alpine 环境
# 下载 Alpine minirootfs（armhf 版本）

wget https://dl-cdn.alpinelinux.org/alpine/v3.16/releases/armhf/alpine-minirootfs-3.16.9-armhf.tar.gz

# 重新构建 rootfs

mkdir -p ./rootfs_new
sudo tar xzf alpine-minirootfs-3.16.9-armhf.tar.gz -C ./rootfs_new

# 安装必要工具

sudo chroot /home/dls/jyd/rootfs_new /bin/sh -c "apk add bash build-base"


cd /home/dls/jyd

# 用 tar 覆盖合并（保留目标目录原有文件，Alpine 填补缺失项）

sudo tar xzf alpine-minirootfs-3.16.9-armhf.tar.gz -C rootfs --overwrite

# 或者如果 rootfs_new 已经解压好了，用 rsync 合并（更可控）

sudo rsync -a --ignore-existing rootfs_new/ rootfs/

sudo ./mount_img.sh 2026-05-09-15-51-b943ff.img

sudo ./mount_img.sh 2026-05-18-15-02-b943ff.img

cd /home/dls/jyd

# 2. 扩展 img 文件（增加 200MB）

# 正常挂载
sudo ./mount_img.sh 2026-05-18-15-02-b943ff.img

# 扩容 500MB
sudo ./mount_img.sh --resize 500 2026-05-18-15-02-b943ff.img

# 扩容 1GB，跳过备份
sudo ./mount_img.sh --resize 1024 --no-backup 2026-05-18-15-02-b943ff.img

# 5. 验证空间，剩余空间

df -h rootfs
