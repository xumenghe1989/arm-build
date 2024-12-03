# 项目介绍

- 本项目用于基于 openKylin V1.0 版本制作嵌入式系统镜像。
- 该项目目前支持 ARM 架构的飞腾 E2000D 平台的双椒派、树莓派 4B、飞腾派；RISC-V 架构的赛昉 VisionFive2 平台、Lotus2 平台
- ARM 架构板卡适配 UKUI-Embedded 桌面环境；RISC-V 架构两款板卡暂不支持桌面环境

# 工具使用方法

> **注意事项**：如果在 x86 架构机器上制作其他架构镜像，需要安装这两个包
> `sudo apt install binfmt-support qemu-user-static`，但由于不同架构指令转换会导致制作速度较慢，所以推荐使用和目标镜像相同架构的机器进行制作，速度会比较快。

1. 检查系统环境, 安装必要的命令工具

   ```sh
   check-env.sh
   ```

2. 制作镜像

- 双椒派

  ```sh
  okbuild.sh -p prop_chilliepi
  ```

- 树莓派 4B

  ```sh
  okbuild.sh -p prop_rpi4b
  ```

- VisionFive2

  ```sh
  okbuild.sh -p prop_vf2
  ```

- Lotus2 开发板

  ```sh
  okbuild.sh -p prop_lotus2
  ```

- 飞腾派

  ```sh
  # 2GB 版本
  okbuild.sh -p prop_phytiumpi_2G

  # 4GB 版本
  okbuild.sh -p prop_phytiumpi_4G
  ```

# 开发板启动方法

> 用户名: openkylin, 密码: openkylin

## 双椒派

> 双椒派上推荐使用金士顿 SDCard

- 烧录镜像
  `sudo xz -dk openKylin-1.0.2-chilliepi-arm64.img.xz -c | sudo dd of=/dev/<your sdcard> status=progress`

- 插上电源, 快速按任意键, 使其到 u-boot 命令行界面

- 设置 U-boot 启动参数

```sh
setenv bootargs console=ttyAMA1,115200  audit=0 earlycon=pl011,0x2800d000 root=/dev/mmcblk1p2 rootdelay=3 rw;
setenv bootcmd 'mmc dev 1;fatload mmc 1:1 0x90000000 e2000d-chilli.dtb;fatload mmc 1:1 0x90100000 Image;booti 0x90100000 - 0x90000000;'
saveenv
```

- 拔下电源, 拔下 SDCard, 插上 SDCard, 再插上电源, 即可启动系统
- 若 UI 桌面环境体验较差，可使用`apt install xface4`命令安装轻量级 UI。该平台更推荐使用 Qt 程序直接绘图。

## 树莓派 4B

- 烧录镜像
  `sudo xz -dk openKylin-1.0.2-rpi4b-arm64.img.xz -c | sudo dd of=/dev/<your sdcard> status=progress`

- 将烧录好的 Sdcard 插在树莓 4B，插上电源即可启动

## VisonFive2

- 烧录镜像
  `sudo xz -dk openKylin-1.0.2-visionfive2-riscv64.img.xz -c | sudo dd of=/dev/<your sdcard> status=progress`

- 将烧录好的 Sdcard 插在 VisionFive2 开发板上，插上电源即可启动

## Lotus2

- Lotus2 不需要 dd，将 Sdcard 格式化为 ext4，再将 `openKylin-1.0.2-lotus2-riscv64.tar.gz` 解压到 `sdcard` 上即可

## 飞腾派

- 烧录镜像
  `sudo xz -dk openKylin-1.0.2-phytiumpi-arm64.img.xz -c | sudo dd of=/dev/<your sdcard> status=progress`

- 将烧录好的 Sdcard 插在 飞腾派 开发板上，插上电源即可启动

# 开发板内核地址

- 双椒派：由于板卡厂商内核授权问题，暂不开源，可使用[飞腾官方内核](https://gitee.com/phytium_embedded/phytium-linux-kernel/tree/linux-4.19/)编译，设备树描述文件可使用 openKylin 1.0 系统镜像中的设备树。
- 树莓派 4B：https://gitee.com/openkylin/raspberrypi-kernel-5.15
- VisionFive2：https://gitee.com/openkylin/visionfive2-kernel-5.10
- Lotus2：https://gitee.com/openkylin/lotus2-kernel-5.15
- 飞腾派: https://gitee.com/openkylin/phytium-kernel-4.19

# 使用到的开源仓库地址

- debootstrap: https://salsa.debian.org/installer-team/debootstrap
- VisionFive2: https://github.com/starfive-tech/VisionFive2
- raspberrypi: https://github.com/raspberrypi/firmware
