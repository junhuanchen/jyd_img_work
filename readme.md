# webdav 用法

apk add rclone
rclone serve webdav / --addr :8080 --user admin --pass yourpassword

cadaver http://localhost:8080

命令行管理webdav

python3 -m http.server 8080 服务配置 index.html

https://cdn.jsdelivr.net/npm/webdav@5.3.0/dist/

有 node 和 web 版本的 webdav 提供，前端用 web 版本

提供脚本测试 ./install-webdav.sh install admin secret 9999 /

## 常规制作步骤

# 最快方法：直接切分，不压缩
split -b 1000M maixpy3_aiplne_0717.zip maixpy3_aiplne_0717.zip.

# 合并还原
cat maixpy3_aiplne_0717.zip.* > maixpy3_aiplne_0717_restored.zip

### 没系统就解压构建 rootfs

wget https://dl-cdn.alpinelinux.org/alpine/v3.16/releases/armhf/alpine-minirootfs-3.16.9-armhf.tar.gz

mkdir -p ./rootfs_new

sudo tar xzf alpine-minirootfs-3.16.9-armhf.tar.gz -C ./rootfs_new

### 先扩容系统，再合并才有空间保存

sudo ./mount_img.sh --resize 8192 2026-06-07-16-43-98500e.img

cd ..

sudo rsync -a --ignore-existing rootfs_new/ rootfs/

sudo chroot rootfs /bin/sh

apk update

apk add --repository https://mirrors.aliyun.com/alpine/v3.16/main/ bash python3 build-base opencv-dev tinyalsa-dev zlib-dev cmake

下面快一些

apk add --repository https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.16/main bash python3 build-base tinyalsa-dev zlib-dev cmake

apk add --repository https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.16/main opencv-dev 

apk add libstdc++ libgcc

## 拷贝 sdk https://github.com/Zluster/jyd_tdl_app

mkdir ./rootfs/mnt/git/

cp -r ../jyd_tdl_app/ ./rootfs/mnt/git/jyd_tdl_app/

然后得到的 img 就是了。


## 以下为备忘命令

# 1. 先安装 QEMU（如果还没装）

sudo apt install qemu-user-static binfmt-support

# 2. 复制 qemu 到 rootfs

sudo mkdir -p /home/dls/jyd/rootfs/usr/bin
sudo cp /usr/bin/qemu-arm-static /home/dls/jyd/rootfs/usr/bin/

# 3. 用 sh 进入（Alpine 没有 bash）

sudo chroot rootfs /bin/sh

# 4. 进入后安装 bash（可选）

echo "nameserver 223.5.5.5" > /etc/resolv.conf

echo "nameserver 8.8.8.8" > /etc/resolv.conf

apk update && apk add bash python3 build-base

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

sudo ./mount_img.sh 2026-06-03-14-35-b943ff.img

sudo ./mount_img.sh 2026-05-18-15-02-b943ff.img

cd /home/dls/jyd

# 2. 扩展 img 文件（增加 200MB）

# 正常挂载

sudo ./mount_img.sh 2026-05-18-15-02-b943ff.img

# 扩容 2048MB
sudo ./mount_img.sh --resize 2048 2026-05-18-15-02-b943ff.img

# 扩容 1GB，跳过备份
sudo ./mount_img.sh --resize 1024 --no-backup 2026-05-18-15-02-b943ff.img

# 5. 验证空间，剩余空间

df -h rootfs

# maixpy3

我今天抽空迁移了我的 maixpy3 到算能平台了，提供了 image 模块 和 maix 通用的 linux 封装，屏蔽了 display 和 camera 的实现，image 模块的文档参考
https://wiki.sipeed.com/soft/maixpy3/zh/usage/vision/maixpy3-example.html
注意，我换了 opencv-moblie .a 静态链接实现，不支持 png 格式和 ttf 字体加载了。

https://github.com/junhuanchen/MaixPy3/tree/jyd

https://github.com/junhuanchen/libmaix/tree/jyd

编译需要在 aiplne 镜像里进行，交叉编译提供不了 python 的编译环境，除非全部迁移到交叉编译里

待会我编译的系统，也一起发出来备份，纯粹拿来编译我的 maixpy3 库的代码，后续我们基于这个环境进行 python 代码的封装即可，其他情况下，直接使用 pip install dist/maixpy3-0.5.4-cp310-cp310-linux_armv7l.whl --no-deps 完成安装

编译需要的依赖
apk add py3-pip python3-dev
python3 -m pip install pybind11
apk add py3-wheel py3-packaging

项目名和包名可以最后修改成竞业达的 dara
