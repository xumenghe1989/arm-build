#!/bin/bash

FC0="30m" # BLACK
FC1="31m" # RED
FC2="32m" # GREEN
FC3="33m" # YELLOW
FC4="34m" # BLUE
FC5="35m" # PURPLE
FC6="36m" # CYAN
FC7="37m" # WHITE

BC0="40m" # BLACK
BC1="41m" # RED
BC2="42m" # GREEN
BC3="43m" # YELLOW
BC4="44m" # BLUE
BC5="45m" # PURPLE
BC6="46m" # CYAN
BC7="47m" # WHITE

function colorEcho() {
    echo -en "\033[${1}${*:2}\033[0m"
}
function color_error() {
    echo -e "\033[${FC1}${*}\033[0m"
}
function color_warn() {
    echo -e "\033[${FC3}${*}\033[0m"
}
function color_info() {
    echo -e "\033[${FC6}${*}\033[0m"
}

# 仅打印
function MY_LOG() {
    echo " => $*"
}
# 打印 并 执行
function MY_LOG_EXEC() {
    echo " => $*"
    eval "$*"
}

# 配置sudo免密
function config_sudo() {
    if [ $(id -u) != 0 ]; then
        sudo tee /etc/sudoers.d/$USER <<EOF
$USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    fi
}

# 检查是否安装指定包
function check_package() {
    pkg_name="$1"
    if [ -n "${pkg_name}" ]; then
        if ! dpkg -l | grep "^ii  ${pkg_name}"; then
            sudo apt-get install -y -qq "${pkg_name}"
        fi
    fi
}

# 宿主机挂载 设备节点 到 rootfs
function mount_host_to_target() {
    sudo mount --bind /dev ${1}/dev
    sudo mount --bind /run ${1}/run
    sudo mount -t devpts devpts ${1}/dev/pts
    sudo mount -t proc proc ${1}/proc
    sudo mount -t sysfs sysfs ${1}/sys
}

# 卸载宿主设备节点
function umount_target() {
    sudo umount -l ${1}/* >/dev/null 2>&1 || true
    sudo umount ${1} >/dev/null 2>&1 || true
}

# 制作基础根文件系统
function do_rootfs() {
    # 先删除 原有 rootfs 目录
    if [ ! -f "${ROOTFS_DIR}.done" ]; then
        umount_target "${ROOTFS_DIR}"
        MY_LOG_EXEC "sudo rm -rf ${ROOTFS_DIR}"

        # debootstrap 参数
        DEBOOTSTRAP_ARGS="--no-check-gpg --variant=minbase --arch=${VK_ARCH} --components=main --include=openkylin-keyring,systemd-sysv ${VK_SUITE} ${ROOTFS_DIR} ${VK_MIRROR} gutsy"

        # 制作 rootfs
        MY_LOG_EXEC "sudo debootstrap ${DEBOOTSTRAP_ARGS}"

        # 记录基础rootfs的包列表，给第2步升级包版本用
        # sudo chroot "${ROOTFS_DIR}" bash -c "dpkg-query -W --showformat='\${Package} \${Version}\n' > /rootfs.deblist"
        # cp "${ROOTFS_DIR}"/rootfs.deblist "${ROOTFS_DIR}".rootfs.deblist
        sudo chroot "${ROOTFS_DIR}" bash -c "dpkg-query -W --showformat='\${Package} \${Version}\n'" >"${ROOTFS_DIR}".rootfs.deblist

        sudo rm -rf ${ROOTFS_DIR}/var/cache/apt/archives/*.deb
        if (: "${VK_KEEP_VAR_LIB_APT_LISTS}") 2>/dev/null && [ "${VK_KEEP_VAR_LIB_APT_LISTS}" = "y" ]; then
            sudo rm -rf ${ROOTFS_DIR}/var/cache/apt/*.bin
            sudo rm -rf ${ROOTFS_DIR}/var/lib/apt/lists/*_Packages
            sudo rm -rf ${ROOTFS_DIR}/var/lib/apt/lists/*_InRelease
            sudo rm -rf ${ROOTFS_DIR}/var/lib/apt/lists/*_Translation*
            sudo rm -rf ${ROOTFS_DIR}/root/.bash_history
            sudo rm -rf ${ROOTFS_DIR}/tmp/*
        fi

        # rootfs制作完成
        MY_LOG_EXEC "touch ${ROOTFS_DIR}.done"
    fi
}

# 进入根文件系统进行安装、配置
function do_config() {
    # 需要升级基础rootfs
    if (: "${VK_UPDATE}") 2>/dev/null && [ "${VK_UPDATE}" = "y" ] && [ "${VK_CURRENT_TASK}" = "config" ] && [ ! -f "${ROOTFS_DIR}.rootfs-update.deblist" ]; then
        MY_LOG_EXEC "sudo cp -v ${ROOTFS_DIR}.rootfs.deblist ${ROOTFS_DIR}/rootfs.deblist"
    fi

    # 挂载
    umount_target "${ROOTFS_DIR}"
    mount_host_to_target ${ROOTFS_DIR}

    # 拷贝配置到 ${ROOTFS_DIR}/config
    sudo rm -rf ${ROOTFS_DIR}/config
    sudo mkdir -p ${ROOTFS_DIR}/config
    sudo cp -v ${CURRENT_DIR}/config/*.sh ${ROOTFS_DIR}/config/
    if [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        sudo cp -r ${CURRENT_DIR}/config/${CONF}/. ${ROOTFS_DIR}/config/
        # 制作
        sudo chroot ${ROOTFS_DIR} /usr/bin/env -i \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            HOME=/root \
            LC_ALL=C \
            DEBIAN_FRONTEND=noninteractive \
            APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn \
            bash -euo pipefail /config/main.sh "$(set | grep "^VK_" | xargs)"
    else
        echo "'config/${CONF}' not exits!"
    fi

    # 卸载
    umount_target ${ROOTFS_DIR}

    # 参考分析用
    sudo rm -rf ${ROOTFS_DIR}-config
    # sudo cp -rf -a ${ROOTFS_DIR}/config ${ROOTFS_DIR}-config
    sudo rm -rf ${ROOTFS_DIR}/config

    # 记录包列表
    if [ "${VK_CURRENT_TASK}" == "config" ]; then
        sudo chroot ${ROOTFS_DIR} dpkg -l | grep ^i | awk '{print $2,$3}' >${ROOTFS_DIR}.deblist
    fi

    # 删除 update 包列表
    if [ -f "${ROOTFS_DIR}"/rootfs-update.deblist ] && [ ! -f "${ROOTFS_DIR}".rootfs-update.deblist ]; then
        cp -v "${ROOTFS_DIR}"/rootfs-update.deblist "${ROOTFS_DIR}".rootfs-update.deblist
    fi
    sudo rm -v -rf "${ROOTFS_DIR}"/rootfs*.deblist
}

# 将 rootfs 打为 tar 包
function do_tar() {
    MY_LOG_EXEC "sudo tar zcf ${ROOTFS_DIR}.tar.gz --numeric-owner -C ${ROOTFS_DIR} ."
    md5sum ${ROOTFS_DIR}.tar.gz >${ROOTFS_DIR}.tar.gz.md5
}

function do_iso() {
    umount_target "${ROOTFS_DIR}-${VK_CURRENT_TASK}/${ROOTFS_DIR}"
    sudo rm -rf "${ROOTFS_DIR}-${VK_CURRENT_TASK}"
    mkdir -pv "${ROOTFS_DIR}-${VK_CURRENT_TASK}"
    sudo cp -rf -a "${ROOTFS_DIR}" "${ROOTFS_DIR}-${VK_CURRENT_TASK}"
    pushd "${ROOTFS_DIR}-${VK_CURRENT_TASK}"

    do_config

    # 记录包列表
    sudo chroot ${ROOTFS_DIR} dpkg -l | grep ^i | awk '{print $2,$3}' >${ROOTFS_DIR}.${VK_CURRENT_TASK}.deblist

    # 镜像名称
    ISO_FILENAME="${ROOTFS_DIR}.iso"
    CDROM_DIR="${ROOTFS_DIR}-cdrom"

    sudo rm -rf ${CDROM_DIR}
    mkdir -pv ${CDROM_DIR}/{casper,boot/grub,EFI/BOOT}

    # 拷贝 内核 和 initrd
    if [ -f ${ROOTFS_DIR}/boot/vmlinuz ] && [ -f ${ROOTFS_DIR}/boot/initrd.img ]; then
        # 标准内核情况
        sudo cp -v ${ROOTFS_DIR}/boot/vmlinuz ${CDROM_DIR}/casper/vmlinuz
        sudo cp -v ${ROOTFS_DIR}/boot/initrd.img ${CDROM_DIR}/casper/initrd.lz
    else
        # 没有内核软链接文件的情况
        VMLINUXZ=$(sudo find ${ROOTFS_DIR}/boot -name "vmlinuz*" | head -n1)
        INITRD_IMG=$(sudo find ${ROOTFS_DIR}/boot -name "initrd*" | head -n1)
        sudo cp -v ${VMLINUXZ} ${CDROM_DIR}/casper/vmlinuz
        sudo cp -v ${INITRD_IMG} ${CDROM_DIR}/casper/initrd.lz
    fi

    echo "---> mksquash"
    [ -f ${CDROM_DIR}/casper/filesystem.squashfs ] && sudo rm -rf ${CDROM_DIR}/casper/filesystem.squashfs
    [ -f ${CDROM_DIR}/casper/filesystem.squashfs ] || sudo mksquashfs ${ROOTFS_DIR} ${CDROM_DIR}/casper/filesystem.squashfs -quiet # -comp xz -no-progress
    printf $(sudo du -sx --block-size=1 ${ROOTFS_DIR} | cut -f1) >${CDROM_DIR}/casper/filesystem.size

    # iso grub菜单项
    cat >${CDROM_DIR}/boot/grub/grub.cfg <<EOF
set default=0
set timeout=3

set color_normal=white/black
set color_highlight=black/light-gray

menuentry "install openkylin" {
    linux   /casper/vmlinuz boot=casper only-ubiquity locale=zh_CN quiet splash
    initrd  /casper/initrd.lz
}
EOF

    if [ "${VK_ARCH}" = "arm64" ]; then
        EFINAME="bootaa64.efi"
    elif [ "${VK_ARCH}" = "amd64" ]; then
        EFINAME="bootx64.efi"
    fi

    # efi
    if [ -f "${CURRENT_DIR}/${EFINAME}" ]; then
        cp -v ${CURRENT_DIR}/${EFINAME} ${CDROM_DIR}/EFI/BOOT/${EFINAME}
    fi

    dd if=/dev/zero of=${CDROM_DIR}/boot/grub/efi.img bs=1M count=10
    mkfs.vfat ${CDROM_DIR}/boot/grub/efi.img
    mmd -i ${CDROM_DIR}/boot/grub/efi.img efi efi/boot
    mcopy -i ${CDROM_DIR}/boot/grub/efi.img ${CDROM_DIR}/EFI/BOOT/${EFINAME} ::efi/boot/

    [ -d ${CURRENT_DIR}/config/cdrom ] && cp -r ${CURRENT_DIR}/config/cdrom/. ${CDROM_DIR}

    sudo mkisofs -input-charset utf-8 -J -r -V openKylin -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -o ${ISO_FILENAME} ${CDROM_DIR}
    md5sum "${ISO_FILENAME}" >"${ISO_FILENAME}".md5
    cp -rf "${ISO_FILENAME}"* ..
    cp -rf ./*.deblist ..

    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        cp -rf ${ISO_FILENAME}* ..
        cp -rf *.deblist ..
        popd
    fi

    if [ -z "${VK_KEEP_IMAGE_DIR}" ] || [ "${VK_KEEP_IMAGE_DIR}" != "y" ]; then
        echo "---> 删除 ${VK_CURRENT_TASK} 制作目录，节省空间"
        sudo rm -rf "${ROOTFS_DIR}-${VK_CURRENT_TASK}"
    else
        echo "---> 保留 ${ROOTFS_DIR}-${VK_CURRENT_TASK} 制作目录"
    fi
}

# 双椒派 镜像
function do_img_chilliepi() {
    umount_target "${ROOTFS_DIR}-img/${ROOTFS_DIR}"
    sudo rm -rf "${ROOTFS_DIR}-img"
    mkdir -pv "${ROOTFS_DIR}-img"
    sudo cp -rf -a "${ROOTFS_DIR}" "${ROOTFS_DIR}-img"
    pushd "${ROOTFS_DIR}-img"

    do_config

    # 磁盘文件名
    IMAGE_FILE="${ROOTFS_DIR}.img"

    # 记录包列表
    sudo chroot ${ROOTFS_DIR} dpkg -l | grep ^i | awk '{print $2,$3}' >${IMAGE_FILE}.deblist

    # 计算rootfs目录大小
    dusize=$(sudo du -sm ${ROOTFS_DIR} | awk '{print $1}')
    size=$((${dusize} + 128 + 2048))

    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=${size} status=progress

    # boot分区
    sgdisk -n 0:0:+128M -c 0:boot "${IMAGE_FILE}" >/dev/null
    # 根分区
    sgdisk -n 0:0:0 -c 0:root "${IMAGE_FILE}" >/dev/null

    # sgdisk -p "${IMAGE_FILE}"

    DISK_PATH=$(readlink -f "${IMAGE_FILE}")
    LOOP_DEV=$(losetup -l -O NAME,BACK-FILE | grep "${DISK_PATH}" | awk '{print $1}')

    if [ -z "${LOOP_DEV}" ]; then
        LOOP_DEV=$(sudo losetup -f)
        # 将镜像关联到loop设备上
        sudo losetup -P ${LOOP_DEV} "${IMAGE_FILE}"
        # sudo partprobe ${LOOP_DEV}
    fi
    echo ${LOOP_DEV}

    # 格式化分区
    yes | sudo mkfs.vfat -n BOOT ${LOOP_DEV}p1
    yes | sudo mkfs.ext4 -Fq -L ROOT ${LOOP_DEV}p2

    part1_uuid=$(sudo blkid -s UUID -o value ${LOOP_DEV}p1)
    part2_uuid=$(sudo blkid -s UUID -o value ${LOOP_DEV}p2)

    echo part1_uuid=${part1_uuid}
    echo part2_uuid=${part2_uuid}

    # 拷贝文件
    mkdir -p {p1,p2}
    sudo mount ${LOOP_DEV}p1 ./p1/
    sudo mount ${LOOP_DEV}p2 ./p2/

    # copy boot
    sudo cp -v -rf -a ${ROOTFS_DIR}/boot/. ./p1/

    echo "---> copy rootfs"
    sudo cp -rf -a ${ROOTFS_DIR}/. ./p2/

    echo "---> generate fstab"
    sudo tee ./p2/etc/fstab <<EOF
UUID=${part2_uuid}   /           ext4    rw,relatime 0 1
UUID=${part1_uuid}   /boot       vfat    nodev,noexec,rw   0       2
EOF

    sudo umount ./p1 ./p2
    rmdir p1 p2
    sudo losetup -d ${LOOP_DEV}

    xz -zkv --extreme --threads=0 ${IMAGE_FILE}
    md5sum ${IMAGE_FILE}.xz >${IMAGE_FILE}.xz.md5

    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        cp -rf ${IMAGE_FILE}.xz* ..
        cp -rf *.deblist ..
        popd
    fi

    if [ -z "${VK_KEEP_IMAGE_DIR}" ] || [ "${VK_KEEP_IMAGE_DIR}" != "y" ]; then
        echo "---> 删除 img 制作目录，节省空间"
        sudo rm -rf "${ROOTFS_DIR}-img"
    else
        echo "---> 保留 ${ROOTFS_DIR}-img 制作目录"
    fi
}

# 树莓派 4B
function do_img_rpi4b() {
    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        umount_target "${ROOTFS_DIR}-img/${ROOTFS_DIR}"
        sudo rm -rf "${ROOTFS_DIR}-img"
        mkdir -pv "${ROOTFS_DIR}-img"
        sudo cp -rf -a "${ROOTFS_DIR}" "${ROOTFS_DIR}-img"
        pushd "${ROOTFS_DIR}-img"

        do_config
    fi

    # 磁盘文件名
    IMAGE_FILE="${ROOTFS_DIR}.img"

    # 记录包列表
    sudo chroot ${ROOTFS_DIR} dpkg -l | grep ^i | awk '{print $2,$3}' >${IMAGE_FILE}.deblist

    # 计算rootfs目录大小
    dusize=$(sudo du -sm ${ROOTFS_DIR} | awk '{print $1}')
    size=$((${dusize} + 128 + 1024))

    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=${size} status=progress
    parted -s ${IMAGE_FILE} mktable msdos
    parted -s ${IMAGE_FILE} mkpart primary fat32 1MiB 128MiB
    parted -s ${IMAGE_FILE} mkpart primary ext4 128MiB 100%
    parted -s ${IMAGE_FILE} set 1 boot on

    DISK_PATH=$(readlink -f "${IMAGE_FILE}")
    LOOP_DEV=$(losetup -l -O NAME,BACK-FILE | grep "${DISK_PATH}" | awk '{print $1}')

    if [ -z "${LOOP_DEV}" ]; then
        LOOP_DEV=$(sudo losetup -f)
        # 将镜像关联到loop设备上
        sudo losetup -P ${LOOP_DEV} "${IMAGE_FILE}"
        # sudo partprobe ${LOOP_DEV}
    fi
    echo ${LOOP_DEV}

    # 格式化分区
    yes | sudo mkfs.vfat -n BOOT -F 32 ${LOOP_DEV}p1
    yes | sudo mkfs.ext4 -Fq -L ROOT ${LOOP_DEV}p2

    part1_uuid=$(sudo blkid -s UUID -o value ${LOOP_DEV}p1)
    part2_uuid=$(sudo blkid -s UUID -o value ${LOOP_DEV}p2)

    echo part1_uuid=${part1_uuid}
    echo part2_uuid=${part2_uuid}

    ROOT_TARGET="${ROOTFS_DIR}-target"
    mkdir -pv ${ROOT_TARGET}
    sudo mount ${LOOP_DEV}p2 ${ROOT_TARGET}
    sudo mkdir -p ${ROOT_TARGET}/boot
    sudo mount ${LOOP_DEV}p1 ${ROOT_TARGET}/boot

    echo "---> copy rootfs"
    sudo cp -rf -a ${ROOTFS_DIR}/. ./${ROOT_TARGET}/

    echo "---> generate fstab"
    sudo tee ${ROOT_TARGET}/etc/fstab <<EOF
UUID=${part2_uuid}   /           ext4    rw,relatime 0 1
UUID=${part1_uuid}   /boot       vfat    nodev,noexec,rw   0       2
EOF

    # copy boot
    git clone https://gitee.com/openkylin/bootfiles-embedded.git
    sudo cp -v -rf ./bootfiles-embedded/rpi4b/boot/. ./${ROOT_TARGET}/boot

    sudo tee ./${ROOT_TARGET}/boot/cmdline.txt <<EOF
console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait
EOF

    sudo tee ./${ROOT_TARGET}/boot/config.txt <<EOF
[all]
kernel=vmlinuz-5.15.92-v8+
cmdline=cmdline.txt

[pi4]
max_framebuffers=2
arm_boost=1
dtoverlay=vc4-fkms-v3d

[all]
dtparam=audio=on
dtparam=i2c_arm=on
dtparam=spi=on
disable_overscan=1
dtoverlay=vc4-kms-v3d
dtoverlay=dwc2
camera_auto_detect=1
display_auto_detect=1
arm_64bit=1
dtparam=audio=on
enable_uart=1
enable_gic=1
dtoverlay=pi3-miniuart-bt
force_turbo=1
EOF

    sync

    sudo umount ${ROOT_TARGET}/boot
    sudo umount ${ROOT_TARGET}
    sudo losetup -d ${LOOP_DEV}

    xz -zkv --extreme --threads=0 ${IMAGE_FILE}
    md5sum ${IMAGE_FILE}.xz >${IMAGE_FILE}.xz.md5

    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        cp -rf ${IMAGE_FILE}.xz* ..
        cp -rf *.deblist ..
        popd
    fi

    if [ -z "${VK_KEEP_IMAGE_DIR}" ] || [ "${VK_KEEP_IMAGE_DIR}" != "y" ]; then
        echo "---> 删除 img 制作目录，节省空间"
        sudo rm -rf "${ROOTFS_DIR}-img"
    else
        echo "---> 保留 ${ROOTFS_DIR}-img 制作目录"
    fi
}

function do_img_vf2() {
    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        umount_target "${ROOTFS_DIR}-img/${ROOTFS_DIR}"
        sudo rm -rf "${ROOTFS_DIR}-img"
        mkdir -pv "${ROOTFS_DIR}-img"
        sudo cp -rf -a "${ROOTFS_DIR}" "${ROOTFS_DIR}-img"
        pushd "${ROOTFS_DIR}-img"

        do_config
    fi

    # 磁盘文件名
    IMAGE_FILE="${ROOTFS_DIR}.img"

    # 记录包列表
    sudo chroot ${ROOTFS_DIR} dpkg -l | grep ^i | awk '{print $2,$3}' >${IMAGE_FILE}.deblist

    # 计算rootfs目录大小
    dusize=$(sudo du -sm ${ROOTFS_DIR} | awk '{print $1}')
    size=$((${dusize} + 64 + 256))

    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count=${size} status=progress

    sgdisk --clear --set-alignment=2 \
        --new=1:4096:8191 --change-name=1:spl --typecode=1:2E54B353-1271-4842-806F-E436D6AF6985 \
        --new=2:8192:16383 --change-name=2:uboot --typecode=2:BC13C2FF-59E6-4262-A352-B275FD6F7172 \
        --new=3:16384:+64M --change-name=3:system --typecode=3:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
        --new=4:0:-0 --change-name=4:rootfs --typecode=4:0x8300 \
        "${IMAGE_FILE}"

    DISK_PATH=$(readlink -f "${IMAGE_FILE}")
    LOOP_DEV=$(losetup -l -O NAME,BACK-FILE | grep "${DISK_PATH}" | awk '{print $1}')

    if [ -z "${LOOP_DEV}" ]; then
        LOOP_DEV=$(sudo losetup -f)
        # 将镜像关联到loop设备上
        sudo losetup -P ${LOOP_DEV} "${IMAGE_FILE}"
        # sudo partprobe ${LOOP_DEV}
    fi
    echo ${LOOP_DEV}

    # spl and uboot for vf2
    U_BOOT_SPL="https://www.openkylin.top/public/software/Embedded/visionfive2/u-boot-spl.bin.normal.out"
    U_BOOT_FILE="https://www.openkylin.top/public/software/Embedded/visionfive2/visionfive2_fw_payload.img"
    wget -qO- ${U_BOOT_SPL} | sudo dd of=${LOOP_DEV}p1 status=progress
    wget -qO- ${U_BOOT_FILE} | sudo dd of=${LOOP_DEV}p2 status=progress

    # 格式化分区
    sudo mkfs.vfat ${LOOP_DEV}p3
    sudo mkfs.ext4 ${LOOP_DEV}p4
    sudo dosfslabel ${LOOP_DEV}p3 BOOT
    sudo e2label ${LOOP_DEV}p4 ROOT

    ROOT_TARGET="${ROOTFS_DIR}-target"
    mkdir -pv ${ROOT_TARGET}
    # mount root partition
    sudo mount ${LOOP_DEV}p4 ${ROOT_TARGET}
    sudo mkdir -p ${ROOT_TARGET}/boot
    sudo mount ${LOOP_DEV}p3 ${ROOT_TARGET}/boot

    echo "---> copy rootfs"
    sudo cp -rf -a ${ROOTFS_DIR}/. ./${ROOT_TARGET}/

    echo "---> generate fstab"
    sudo tee ${ROOT_TARGET}/etc/fstab <<EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass> 
LABEL=ROOT  /               ext4    errors=remount-ro 0       1
LABEL=BOOT  /boot           vfat    nodev,noexec,rw   0       2
EOF

    # uEnv.txt
    echo "---> generate uEnv.txt"
    sudo tee "${ROOT_TARGET}"/boot/uEnv.txt <<EOF
fdt_high=0xffffffffffffffff
initrd_high=0xffffffffffffffff
kernel_addr_r=0x44000000
kernel_comp_addr_r=0x90000000
kernel_comp_size=0x10000000
fdt_addr_r=0x48000000
ramdisk_addr_r=0x48100000
# Move distro to first boot to speed up booting
boot_targets=distro mmc0 dhcp
# Fix wrong fdtfile name
fdtfile=starfive/jh7110-visionfive-v2.dtb
# Fix missing bootcmd
#bootcmd=run load_distro_uenv;run bootcmd_distro
EOF

    sudo touch "${ROOT_TARGET}"/boot/vf2_uEnv.txt

    # extlinux.conf
    echo "---> generate extlinux.conf"
    sudo mkdir -p ${ROOT_TARGET}/boot/extlinux
    sudo tee ${ROOT_TARGET}/boot/extlinux/extlinux.conf <<EOF
default openkylin
menu title openkylin
prompt 0
timeout 50

label openkylin
	menu label openkylin
	linux /vmlinuz-5.10.79+
	initrd /initrd.img-5.10.79+
	
	fdtdir /dtbs
	append  root=/dev/mmcblk1p4 rw rootwait console=ttyS0,115200 earlycon rootwait
EOF

    # umount
    sudo umount ${ROOT_TARGET}/boot
    sudo umount ${ROOT_TARGET}
    sudo losetup -d ${LOOP_DEV}

    xz -zkv --extreme --threads=0 ${IMAGE_FILE}
    md5sum ${IMAGE_FILE}.xz >${IMAGE_FILE}.xz.md5

    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        cp -rf ${IMAGE_FILE}.xz* ..
        cp -rf *.deblist ..
        popd
    fi

    if [ -z "${VK_KEEP_IMAGE_DIR}" ] || [ "${VK_KEEP_IMAGE_DIR}" != "y" ]; then
        echo "---> 删除 img 制作目录，节省空间"
        sudo rm -rf "${ROOTFS_DIR}-img"
    else
        echo "---> 保留 ${ROOTFS_DIR}-img 制作目录"
    fi
}

function do_img_lotus2() {
    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        umount_target "${ROOTFS_DIR}-img/${ROOTFS_DIR}"
        sudo rm -rf "${ROOTFS_DIR}-img"
        mkdir -pv "${ROOTFS_DIR}-img"
        sudo cp -rf -a "${ROOTFS_DIR}" "${ROOTFS_DIR}-img"
        pushd "${ROOTFS_DIR}-img"

        do_config
    fi

    MY_LOG_EXEC "sudo tar zcf ${ROOTFS_DIR}.tar.gz -C ${ROOTFS_DIR} ."
    md5sum ${ROOTFS_DIR}.tar.gz >${ROOTFS_DIR}.tar.gz.md5
    cp -rf ${ROOTFS_DIR}.tar.gz* ..
    popd

    if [ -z "${VK_KEEP_IMAGE_DIR}" ] || [ "${VK_KEEP_IMAGE_DIR}" != "y" ]; then
        echo "---> 删除 img 制作目录，节省空间"
        sudo rm -rf "${ROOTFS_DIR}-img"
    else
        echo "---> 保留 ${ROOTFS_DIR}-img 制作目录"
    fi
}

# 飞腾派
function do_img_phytiumpi() {
    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        umount_target "${ROOTFS_DIR}-img/${ROOTFS_DIR}"
        sudo rm -rf "${ROOTFS_DIR}-img"
        mkdir -pv "${ROOTFS_DIR}-img"
        sudo cp -rf -a "${ROOTFS_DIR}" "${ROOTFS_DIR}-img"
        pushd "${ROOTFS_DIR}-img"

        do_config
    fi

    # 磁盘文件名
    IMAGE_FILE="${ROOTFS_DIR}.img"

    echo "---> use ${VK_UBOOT_FILE}"

    # 记录包列表
    sudo chroot ${ROOTFS_DIR} dpkg -l | grep ^i | awk '{print $2,$3}' >${IMAGE_FILE}.deblist

    # 计算rootfs目录大小
    dusize=$(sudo du -sm ${ROOTFS_DIR} | awk '{print $1}')
    size=$((${dusize} + 1024))

    # 文件系统放在ext4文件中
    dd if=/dev/zero of="${ROOTFS_DIR}.ext4" bs=1M count=${size} status=progress
    # 格式化ext4
    MY_LOG_EXEC "yes | sudo mkfs.ext4 -Fq -L ROOT ${ROOTFS_DIR}.ext4"

    ROOT_TARGET="${ROOTFS_DIR}-target"
    mkdir -pv ${ROOT_TARGET}
    MY_LOG_EXEC "sudo mount ${ROOTFS_DIR}.ext4 ${ROOT_TARGET}"

    echo "---> copy rootfs"
    MY_LOG_EXEC "sudo cp -rf -a ${ROOTFS_DIR}/. ${ROOT_TARGET}"

    sync

    sudo umount ${ROOT_TARGET}

    # 安装uboot
    echo "---> install uboot"
    (
        # 先删除旧的
        rm -rf ./phyitum-pi/

        mkdir -p ./phyitum-pi/resource
        cp -v ${ROOTFS_DIR}/boot/vmlinuz ./phyitum-pi/resource/vmlinuz

        cd ./phyitum-pi/resource
        wget -R "index.html*,*.deb" -r -np -nd http://factory.openkylin.top/kif/archive/get/repos/phyitumpi/pool/

        # mkimage 依赖 上面拷贝的vmlinuz文件
        mkimage -f ./edu.its ./uImage.itd

        # cp -v ${VK_UBOOT_FILE} fip.bin
        # dd if=./uImage.itd of=./fip.bin bs=1M seek=4
    )

    MY_LOG_EXEC "dd if=./phyitum-pi/resource/${VK_UBOOT_FILE} of=${IMAGE_FILE} conv=notrunc"
    MY_LOG_EXEC "dd if=./phyitum-pi/resource/uImage.itd of=${IMAGE_FILE} bs=1M seek=4 conv=notrunc"
    MY_LOG_EXEC "dd if=./${ROOTFS_DIR}.ext4 of=${IMAGE_FILE} bs=1M seek=64 conv=notrunc"

    echo "---> success"

    xz -zkv --extreme --threads=0 ${IMAGE_FILE}
    md5sum ${IMAGE_FILE}.xz >${IMAGE_FILE}.xz.md5

    if [ -n "${CONF}" ] && [ -d "${CURRENT_DIR}/config/${CONF}" ]; then
        cp -rf ${IMAGE_FILE}.xz* ..
        cp -rf *.deblist ..
        popd
    fi

    if [ -z "${VK_KEEP_IMAGE_DIR}" ] || [ "${VK_KEEP_IMAGE_DIR}" != "y" ]; then
        echo "---> 删除 img 制作目录，节省空间"
        sudo rm -rf "${ROOTFS_DIR}-img"
    else
        echo "---> 保留 ${ROOTFS_DIR}-img 制作目录"
    fi
}
