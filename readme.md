# 1. 先安装 QEMU（如果还没装）
sudo apt install qemu-user-static binfmt-support

# 2. 复制 qemu 到 rootfs
sudo mkdir -p /home/dls/jyd/rootfs/usr/bin
sudo cp /usr/bin/qemu-arm-static /home/dls/jyd/rootfs/usr/bin/

# 3. 用 sh 进入（Alpine 没有 bash）
sudo chroot /home/dls/jyd/rootfs /bin/sh

# 4. 进入后安装 bash（可选）
apk add bash


# 在 chroot 前，先准备 Alpine 环境
# 下载 Alpine minirootfs（armhf 版本）
wget https://dl-cdn.alpinelinux.org/alpine/v3.16/releases/armhf/alpine-minirootfs-3.16.9-armhf.tar.gz

# 重新构建 rootfs
mkdir -p /home/dls/jyd/rootfs_new
sudo tar xzf alpine-minirootfs-3.16.9-armhf.tar.gz -C /home/dls/jyd/rootfs_new

# 安装必要工具
sudo chroot /home/dls/jyd/rootfs_new /bin/sh -c "apk add bash build-base"


cd /home/dls/jyd

# 用 tar 覆盖合并（保留目标目录原有文件，Alpine 填补缺失项）
sudo tar xzf alpine-minirootfs-3.16.9-armhf.tar.gz -C rootfs --overwrite

# 或者如果 rootfs_new 已经解压好了，用 rsync 合并（更可控）
sudo rsync -a --ignore-existing rootfs_new/ rootfs/


sudo ./mount_img.sh 2026-05-09-15-51-b943ff.img

cd /home/dls/jyd

# 1. 先卸载
sudo umount rootfs
sudo umount boot
sudo losetup -d /dev/loop0 2>/dev/null || true

# 2. 扩展 img 文件（增加 200MB）
IMG_FILE="你的镜像文件.img"  # 替换实际文件名
dd if=/dev/zero bs=1M count=200 >> "$IMG_FILE"

# 3. 重新挂载并扩展分区
sudo losetup -fP "$IMG_FILE"
LOOP_DEV=$(losetup -j "$IMG_FILE" | head -1 | cut -d: -f1)
echo "Loop device: $LOOP_DEV"

# 扩展第2分区（rootfs）
sudo parted "$LOOP_DEV" resizepart 2 100%
sudo e2fsck -f "${LOOP_DEV}p2"
sudo resize2fs "${LOOP_DEV}p2"

# 4. 重新挂载
sudo mount "${LOOP_DEV}p1" boot
sudo mount "${LOOP_DEV}p2" rootfs

# 5. 验证空间
df -h rootfs
