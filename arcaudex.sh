#!/bin/bash -xe

## Consolidating arch installation steps ##

### Install Dependencies to Live Image ###

#### pacman -Sy tree git --noconfirm ####

SHP=
USER=
ROOT=
PLT=

set -o errexit

readonly INSTALL_DIR="/root/arcaudex.log"

if [ -f ${INSTALL_DIR} ]; then rm ${INSTALL_DIR}; fi

sudo touch ${INSTALL_DIR}
exec 1>>${INSTALL_DIR}
exec 2>&1


#exec > >(${INSTALL_DIR}  2>/dev/console) 2>&1

### Verify boot mode for uefi

ls /sys/firmware/efi/efivars

### echo and verify ip connection for internet access

ip link

ping archlinux.org -c 4

###  set time and date via ntp

timedatectl set-ntp true

### list connected disks

fdisk -l

###### Nuke

sgdisk -o /dev/$SHP

###### Create 200mb boot partition starting from top

sgdisk -n 0:0:+260M -t 0:ef00 -c 0:"boot" /dev/$SHP

###### Create root partition from the rest of the disk

sgdisk -n 0:0:0 -t 0:8300 -c 0:"shp" /dev/$SHP

###### Check

sgdisk -p /dev/$SHP

### Check Partitions

lsblk /dev/${SHP}

### Create Filesystems

mkfs.fat -F32 /dev/"${SHP}1" # boot partition for uefi

mkfs.ext4 /dev/"${SHP}2" # root partition

###### Check

parted -l

### Mount Root ( / )

mkdir -p /mnt/shp
mount /dev/"${SHP}2" /mnt/shp

### Mount Boot ( /boot )

mkdir -p /mnt/shp/boot
mount /dev/"${SHP}1" /mnt/shp/boot

###### Check

mount | tail -3

### Package Bootstrapping

#### First Pass

pacstrap /mnt/shp base base-devel

#### Second Pass

pacstrap /mnt/shp intel-ucode dosfstools openssh ansible git

### Fstab Everything in the Back

genfstab -pU /mnt/shp >> /mnt/shp/etc/fstab

cat /mnt/shp/etc/fstab

### Configure Boot

#### Bootctl Instead of Grub

bootctl install --path /mnt/shp/boot/

#### Write Bootloader Configs

INSTALL_DIR=/mnt/shp/boot/loader/loader.conf

if [[ -f ${INSTALL_DIR} ]]; then rm -rf ${INSTALL_DIR}; fi

tee -a >${INSTALL_DIR} <<EOL
default ${PLT}
timeout 1
editor 0
EOL

UUID=$(blkid -s PARTUUID -o value /dev/"${SHP}2")

INSTALL_DIR=/mnt/shp/boot/loader/entries/${PLT}.conf

tee -a >${INSTALL_DIR} <<EOL
title   ${PLT}
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=${UUID} rw
EOL

#### Configuration via Arch Chroot

##### Configure Systemd Journal

JOURNAL=/mnt/shp/etc/systemd/journald.conf

###### Shrink log max use

sed -i "s:#SystemMaxUse=:SystemMaxUse=16M:g" ${JOURNAL}

##### Configure Fstab for Noatime

FSTAB=/mnt/shp/etc/fstab

sed -i "s:relatime:noatime:g" ${FSTAB}

##### Configure Locale

CNT=
REG=

arch-chroot /mnt /bin/bash <<EOL
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
export LANG=en_US.UTF-8
echo "LANG=en_US.UTF-8" >> /etc/locale.conf
ln -sf /usr/share/zoneinfo/${CNT}/${REG} /etc/localtime
EOL

##### Top-Level User Configuration

arch-chroot /mnt/shp /bin/bash <<EOL
echo root:${ROOT} | chpasswd 
useradd -mG wheel ${USER} 
echo ${USER}:${USER} | chpasswd
EOL


##### Make Init

HKS="HOOKS=(base udev block filesystems keyboard fsck)"

arch-chroot /mnt/shp /bin/bash <<EOL
sed -i s:^HOOKS.*:"${HKS}":g /mnt/shp/etc/mkinitcpio.conf
mkinitcpio -p linux
EOL
