#!/bin/bash
set -e

CURRENT_FILE=$(readlink -f "$0")
CURRENT_DIR=$(dirname "${CURRENT_FILE}")
# 函数库 优先级 1
. "${CURRENT_DIR}"/functions.sh

function usage() {
    echo -en "USAGE:
$(basename "$0") -p prop_chilliepi  # 双椒派
$(basename "$0") -p prop_lotus2     # lotus2开发板

$(basename "$0") -p prop_rpi4b      # 树莓派4B
$(basename "$0") -p prop_vf2        # VisionFive2

$(basename "$0") -p prop_phytiumpi_2G  # 飞腾派 2GB 版本
$(basename "$0") -p prop_phytiumpi_4G  # 飞腾派 4GB 版本
"
    exit 1
}

# 判断参数个数
if [ $# -eq 0 ]; then
    usage
fi

# 配置sudo免密
if [ "$(id -nu)" != "root" ]; then
    sudo tee "/etc/sudoers.d/${USER}" <<EOF
$USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
fi

ARGS=$(getopt -a -o h,p: -l help,conf:,prop:,mirror:,suite:,name:,arch:,debdir:,tasks:,version: -- "$@")
eval set -- "${ARGS}"

# 参数 优先级 1
while true; do
    case "$1" in
    -h | --help)
        usage
        shift
        ;;
    -p | --prop)
        PROP=$2
        shift
        ;;
    --arch)
        VK_ARCH=$2
        shift
        ;;
    --tasks)
        VK_TASKS=$2
        shift
        ;;
    --)
        break
        ;;
    esac
    shift
done

# 默认选用base目录
CONF=${CONF:-openkylin}

if [ ! -d "${CURRENT_DIR}/config/${CONF}" ]; then
    color_error "${CURRENT_DIR}/config/${CONF} not exist!!"
    usage
fi

# 参数 优先级 2
if [ -f "${CURRENT_DIR}/config/${CONF}/${PROP:-default.prop}" ]; then
    . "${CURRENT_DIR}/config/${CONF}/${PROP:-default.prop}"
fi

# 参数 优先级 3
for item in "$@"; do
    if grep -q "^VK.*=" <<<"${item}"; then
        KEY=${item%%=*}
        VALUE="${item##*=}"
        eval "export ${KEY}='${VALUE}'"
    fi
done

# 参数 优先级 4
if [ -f "${CURRENT_DIR}/config/${CONF}/${VK_ENV}" ]; then
    . "${CURRENT_DIR}/config/${CONF}/${VK_ENV}"
fi

# 是否保留镜像制作目录
VK_KEEP_IMAGE_DIR=${VK_KEEP_IMAGE_DIR:-y}

VK_ARCH=${VK_ARCH:-arm64}
VK_MIRROR=${VK_MIRROR:-http://archive.build.openkylin.top/openkylin}
VK_SUITE=${VK_SUITE:-yangtze}
VK_VERSION=${VK_VERSION:-test}

ROOTFS_DIR="openKylin"
if [ -n "${VK_VERSION}" ]; then
    ROOTFS_DIR="${ROOTFS_DIR}-${VK_VERSION}"
fi
if [ -n "${VK_TERMINAL}" ]; then
    ROOTFS_DIR="${ROOTFS_DIR}-${VK_TERMINAL}"
fi
if [ -n "${VK_BOARD}" ]; then
    ROOTFS_DIR="${ROOTFS_DIR}-${VK_BOARD}"
fi
if [ -n "${VK_ARCH}" ]; then
    ROOTFS_DIR="${ROOTFS_DIR}-${VK_ARCH}"
fi

# 函数库 优先级 2
if [ -f "${CURRENT_DIR}/config/${CONF}/functions.sh" ]; then
    . "${CURRENT_DIR}/config/${CONF}/functions.sh"
fi

color_info "---> args"
set | grep "^VK_" | tee "${ROOTFS_DIR}.prop"

function exit_function() {
    umount_target "${ROOTFS_DIR}"
    umount_target "${ROOTFS_DIR}-iso/${ROOTFS_DIR}"
    umount_target "${ROOTFS_DIR}-img/${ROOTFS_DIR}"

    umount_target ./p1
    umount_target ./p2
    umount_target ./p3

    umount_target "${ROOTFS_DIR}-target"
}

trap "exit_function" 0

umount_target "${ROOTFS_DIR}"

if [ -z "${VK_TASKS}" ]; then
    color_error "---> no task to do!!"
    usage
fi

# 判断是否支持此架构
if ! echo "${VK_ARCH}" | grep -q -E "amd64|arm64|loongarch64|i386|riscv64"; then
    color_error "not support 'ARCH: ${VK_ARCH}'"
    exit
fi

# x86上制作其他架构, 需安装 binfmt-support,qemu-user-static
if [ "$(dpkg --print-architecture)" == "amd64" ] && [ "${VK_ARCH}" != "amd64" ]; then
    check_package binfmt-support
    check_package qemu-user-static
elif [ "$(dpkg --print-architecture)" != "${VK_ARCH}" ]; then
    # 非x86, 提示不能制作其他架构
    color_error "current os is $(dpkg --print-architecture), don't support ${VK_ARCH}!!"
    exit
fi

# 执行任务
##################################################
for task in ${VK_TASKS//,/ }; do
    color_info "---> do_${task}"
    export VK_CURRENT_TASK="${task}"
    do_"${task}"
done | tee "${ROOTFS_DIR}.log"
##################################################
