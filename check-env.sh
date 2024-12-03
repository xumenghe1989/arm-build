#!/bin/bash

set -e

CURRENT_DIR=$(dirname "$(readlink -f "$0")")
. "${CURRENT_DIR}"/functions.sh

config_sudo

# 制作镜像需要安装的包
check_package debootstrap
check_package gdisk
check_package mtools
check_package dosfstools
check_package genisoimage
check_package squashfs-tools
check_package xz-utils

# dtc
check_package device-tree-compiler

# 创建软链接
sudo ln -v -sf "${CURRENT_DIR}"/okbuild.sh /usr/bin/
