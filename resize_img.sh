
# 1. 先卸载
sudo umount rootfs
sudo umount boot
sudo losetup -d /dev/loop0 2>/dev/null || true

# 2. 扩展 img 文件（增加 200MB）
IMG_FILE="2026-05-09-15-51-b943ff.img"  # 替换实际文件名
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