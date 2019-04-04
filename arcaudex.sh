#!/bin/bash -xe

## Consolidating arch installation steps ##

### Install Dependencies to Live Image ###

#### pacman -Sy tree git --noconfirm ####

## Installation Functions ##

function logging {
  set -o errexit
  readonly LOG="/root/arcaudex.log"
  if [ -f ${LOG} ]; then rm ${LOG}; fi
  sudo touch ${LOG}
  exec 1>>${LOG}
  exec 2>&1
}

function network_ntp {
  ### echo and verify ip connection for internet access
  ip link
  ping archlinux.org -c 3
  ###  set time and date via ntp
  if [ $? -eq 0 ]; then timedatectl set-ntp true; fi
}

function partition_creation {
  ### list connected disks
  fdisk -l
  ### Nuke
  sgdisk -o /dev/$disks_sdx
  ### Create 260mb boot partition starting from top of the disk
  sgdisk -n 0:0:+260M -t 0:ef00 -c 0:$disks_labels_boot /dev/$disks_sdx
  ### Create root partition from the rest of the disk
  sgdisk -n 0:0:0 -t 0:8300 -c 0:$disks_labels_root /dev/$disks_sdx
  ### Check
  sgdisk -p /dev/$disks_sdx
}

function filesystem_creation {
  ### Check Partitions
  #lsblk /dev/${disks_sdx}
  parted -l
  ### Create Filesystems
  #### boot partition for uefi
  yes | mkfs.fat -F32 /dev/"${disks_sdx}1"
  #### root partition
  case $disks_rootfs in
    ext4)
      yes | mkfs.ext4 /dev/"${disks_sdx}2"
    ;;
  esac
  ### Check
  parted -l
}

function mount_volumes {
  ### Mount Root ( / )
  mkdir -p /mnt/shp
  mount /dev/"${disks_sdx}2" /mnt/shp
  ### Mount Boot ( /boot )
  mkdir -p /mnt/shp/boot
  mount /dev/"${disks_sdx}1" /mnt/shp/boot
  ### Check
  mount | tail -3
}

function pacstrap_packages {
  ### Package Bootstrapping
  #### First Pass
  pacstrap /mnt/shp ${pacstrap_pass_1[*]}
  #### Second Pass
  pacstrap /mnt/shp ${pacstrap_pass_2[*]}
}

function fstab_generation {
  ### Fstab Everything in the Back
  genfstab -pU /mnt/shp >> /mnt/shp/etc/fstab
  cat /mnt/shp/etc/fstab
}

function boot_configuration {
  ### Configure Boot
  #### Bootctl Instead of Grub
  bootctl install --path /mnt/shp/boot/
  #### Write Bootloader Configs
  INSTALL_DIR=/mnt/shp/boot/loader/loader.conf
  if [[ -f ${INSTALL_DIR} ]]; then rm -rf ${INSTALL_DIR}; fi
  tee -a >${INSTALL_DIR} <<EOL
  default ${boot_entries_default}
  timeout 1
  editor 0
EOL

  UUID=$(blkid -s PARTUUID -o value /dev/"${sdx}2")

  INSTALL_DIR=/mnt/shp/boot/loader/entries/${boot_entries_default}.conf

  tee -a >${INSTALL_DIR} <<EOL
  title   ${boot_entries_default}
  linux   /vmlinuz-linux
  initrd  /initramfs-linux.img
  options root=PARTUUID=${UUID} rw
EOL
}

function filesystem_configuration {
  ### Configuration via Arch Chroot
  #### Configure Systemd Journal
  JOURNAL=/mnt/shp/etc/systemd/journald.conf
  #### Shrink log max use
  sed -i "s:#SystemMaxUse=:SystemMaxUse=16M:g" ${JOURNAL}
  #### Set Storage to Volatile
  sed -i "s:#Storage=auto:Storage=volatile:g" ${JOURNAL}
  #### Configure Fstab for Noatime
  FSTAB=/mnt/shp/etc/fstab
  sed -i "s:relatime:noatime:g" ${FSTAB}
}

function locale_configuration {
  #### Configure Locale
  arch-chroot /mnt/shp /bin/bash <<EOL
  echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
  locale-gen
  export LANG=en_US.UTF-8
  echo "LANG=en_US.UTF-8" >> /etc/locale.conf
  ln -sf /usr/share/zoneinfo/${locale_zone_country}/${locale_zone_region} \
    /etc/localtime
EOL
}

function user_configuration {
  ##### Top-Level User Configuration
  arch-chroot /mnt/shp /bin/bash <<EOL
  echo root:${users_root_password} | chpasswd
  useradd -mG wheel ${users_standard_name}
  echo ${users_standard_name}:${users_standard_password} | chpasswd
EOL
}

function kernel_configuration {
  ##### Make Init
  HKS="HOOKS=(base udev block filesystems autodetect modconf keyboard fsck)"
  arch-chroot /mnt/shp /bin/bash <<EOL
  sed -i s:^HOOKS.*:"${HKS}":g /mnt/shp/etc/mkinitcpio.conf
  mkinitcpio -p linux
EOL
}

## Helper Functions ##

function _parse_yaml {
  # source:  https://github.com/jasperes/bash-yaml/blob/master/script/yaml.sh
  # discussion: https://gist.github.com/pkuczynski/8665367

  local yaml_file=$1
  local prefix=$2
  local s
  local w
  local fs
  s='[[:space:]]*'
  w='[a-zA-Z0-9_.-]*'
  fs="$(echo @|tr @ '\034')"
  (
      sed -e '/- [^\“]'"[^\']"'.*: /s|\([ ]*\)- \([[:space:]]*\)|\1-\'$'\n''  \1\2|g' |
      sed -ne '/^--/s|--||g; s|\"|\\\"|g; s/[[:space:]]*$//g;' \
          -e "/#.*[\"\']/!s| #.*||g; /^#/s|#.*||g;" \
          -e "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
          -e "s|^\($s\)\($w\)${s}[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" |
      awk -F"$fs" '{
          indent = length($1)/2;
          if (length($2) == 0) { conj[indent]="+";} else {conj[indent]="";}
          vname[indent] = $2;
          for (i in vname) {if (i > indent) {delete vname[i]}}
              if (length($3) > 0) {
                  vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
                  printf("%s%s%s%s=(\"%s\")\n", "'"$prefix"'",vn, $2, conj[indent-1],$3);
              }
          }' |
      sed -e 's/_=/+=/g' |
      awk 'BEGIN {
              FS="=";
              OFS="="
          }
          /(-|\.).*=/ {
              gsub("-|\\.", "_", $1)
          }
          { print }'
  ) < "$yaml_file"
}

### Verify boot mode for uefi

#ls /sys/firmware/efi/efivars

## Execution ##

eval $(_parse_yaml dflt.yml)

#logging
network_ntp
partition_creation
filesystem_creation
mount_volumes
pacstrap_packages
fstab_generation
boot_configuration
filesystem_configuration
locale_configuration
user_configuration
kernel_configuration

## Additional Resources and Docs ##

#### https://wiki.archlinux.org/index.php/Installation_guide

#### https://wiki.archlinux.org/index.php/Gdisk
