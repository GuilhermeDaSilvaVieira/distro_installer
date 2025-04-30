#! /usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NO_COLOR='\033[0m'

CHROOT="arch-chroot /mnt"
HOST="mugiwara"
PASSWORD="Pas\$w0rd"
USERS=(
"luffy"
"zoro"
"nami"
"usopp"
"sanji"
"chopper"
"robin"
"franky"
"brook"
"jinbe"
)

# Cleanup from previous runs.
cleanup() {
    umount -R /mnt
}

is_uefi() {
    DIRECTORY_UEFI="/sys/firmware/efi/efivars/"
    if [ -d $DIRECTORY_UEFI ]; then
        echo -e "${GREEN}Supports UEFI${NO_COLOR}"
        echo ""
    else
        echo -e "${RED}Doesn't Support UEFI${NO_COLOR}"
        echo -e "${RED}This is a UEFI only script${NO_COLOR}"
        exit 0
    fi
}

disks () {
    # Partition
    # /boot/EFI  /
    fdisk /dev/sda < fdisk_cmds
    # /home
    fdisk /dev/nvme0n1 < home_fdisk_cmds

    # Encrypt
    cryptsetup -y -v luskFormat /dev/sda2
    cryptsetup open /dev/sda2 root
    cryptsetup -y -v luskFormat /dev/nvme0n1p1
    cryptsetup open /dev/nvme0n1p1 home

    # Add encrypt to hooks (can fail)
    sed -i 's/consolefont block filesystems/consolefont block encrypt filesystems/' /mnt/etc/mkinitcpio.conf
    cat /mnt/etc/mkinitcipio.conf | grep 'HOOKS'

    # Format
    mkfs.fat -n boot -F32 /dev/sda1
    mkfs.ext4 /dev/mapper/root
    mkfs.ext4 /dev/mapper/home

    # Mount
    mount --mkdir /dev/sda1 /mnt/boot
    mount /dev/mapper/root /mnt
    mount --mkdir /dev/mapper/home /mnt/home

    # Prints partition table
    lsblk -f
}

time_and_locale() {
    # Links to your timezone
    $CHROOT ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime

    # Generate /etc/adjtime
    $CHROOT hwclock --systohc

    # Sync Time
    $CHROOT timedatectl set-ntp true

    # Set locale
    sed -i 's/#pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /mnt/etc/locale.gen
    sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen
    sed -i 's/#en_IE.UTF-8 UTF-8/en_IE.UTF-8 UTF-8/' /mnt/etc/locale.gen
    $CHROOT locale-gen
    echo 'LANG=en_US.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_ADDRESS=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_MEASUREMENT=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_MONETARY=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_NAME=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_NUMERIC=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_PAPER=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_TELEFONE=pt_BR.UTF-8' >> /mnt/etc/locale.conf
    echo 'LC_TIME=en_IE.UTF-8' >> /mnt/etc/locale.conf
}

packages() {
    # Pacman config
    sed -i 's/#Color/Color/' /mnt/etc/pacman.conf
    sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 20/' /mnt/etc/pacman.conf
    sed -i 's/#VerbosePkgLists/VerbosePkgLists/' /mnt/etc/pacman.conf
    sed -i '/^ParallelDownloads =/a ILoveCandy' /mnt/etc/pacman.conf
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /mnt/etc/pacman.conf

    # Install all needed packages
    $CHROOT pacman -Sy --noconfirm --needed - < packages.txt
}

# Systemd-boot
bootloader() {
    bootctl --path=/mnt/boot install
    sed -i '/default/d' /mnt/boot/loader/loader.conf
    echo 'default arch-*' >> /mnt/boot/loader/loader.conf
    echo 'title   Arch Linux' >> /mnt/boot/loader/entries/arch.conf
    echo 'linux   /vmlinuz-linux' >> /mnt/boot/loader/entries/arch.conf
    echo 'initrd  /initramfs-linux.img' >> /mnt/boot/loader/entries/arch.conf
    echo 'initrd  /amd-ucode.img' >> /mnt/boot/loader/entries/arch.conf
    echo 'options cryptdevice=UUID=$(blkid -s UUID -o value /dev/sda2):root root=/dev/mapper/root rw quiet splash zswap.enabled=0' >> /mnt/boot/loader/entries/arch.conf
}

create_user() {
    for user in "${USERS[@]}";
    do
        if [[ $user == "luffy" || $user == "robin" ]]; then
            $CHROOT useradd -m -G wheel -s /bin/fish "$user"
        elif [[ $user == "franky" ]]; then
            $CHROOT useradd -m -G wheel,libvirt -s /bin/fish "$user"
        else
            $CHROOT useradd -m -s /bin/fish "$user"
        fi
        echo "$user":$PASSWORD >> passwords.txt
    done
}

systems() {
    # Enable internet, VM, Printing, Bluetooth, System Backup
    for system in NetworkManager libvirtd cups bluetooth timeshift;
    do
        $CHROOT systemctl enable $system
    done
    # Enable syncthing for robin user
    $CHROOT systemctl enable syncthing@robin.service

    # Enable devmon
    echo '[Unit]' >> /mnt/etc/systemd/system/devmon.service
    echo 'Description=Automatically mount devices on plug' >> /mnt/etc/systemd/system/devmon.service
    echo '' >> /mnt/etc/systemd/system/devmon.service
    echo '[Service]' >> /mnt/etc/systemd/system/devmon.service
    echo 'ExecStart=/usr/bin/devmon' >> /mnt/etc/systemd/system/devmon.service
    echo '' >> /mnt/etc/systemd/system/devmon.service
    echo '[Install]' >> /mnt/etc/systemd/system/devmon.service
    echo 'WantedBy=multi-user.target' >> /mnt/etc/systemd/system/devmon.service
    $CHROOT systemctl enable devmon.service
}

zram() {
    echo '[zram0]' >> /mnt/etc/systemd/zram-generator.conf
    echo 'zram-size = min(ram / 2, 4096)' >> /mnt/etc/systemd/zram-generator.conf
    echo 'compression-algorithm = zstd' >> /mnt/etc/systemd/zram-generator.conf
    $CHROOT systemctl daemon-reload
    $CHROOT systemctl enable systemd-zram-setup-@zram0.service
    $CHROOT zramctl
}

aur() {
    arch-chroot -u "${USERS[7]}" /mnt sh -c "
    cd /home/${USERS[7]};
    git clone https://aur.archlinux.org/paru-bin.git;
    cd paru-bin;
    makepkg -sri --noconfirm;
    cd /home/${USERS[7]};
    rm -rf paru-bin;
    "

    # Paru config
    sed -i 's/\#BottomUp/BottomUp/' /mnt/etc/paru.conf
    sed -i 's/\#RemoveMake/RemoveMake/' /mnt/etc/paru.conf
    sed -i 's/\#CleanAfter/CleanAfter/' /mnt/etc/paru.conf
    sed -i 's/\#\[bin\]/\[bin\]/' /mnt/etc/paru.conf
    sed -i 's/\#FileManager = vifm/FileManager = yazi/' /mnt/etc/paru.conf
    sed -i 's/\#Sudo = doas/Sudo = \/bin\/doas/' /mnt/etc/paru.conf

    # Install aur packages
    cp -v aur_packages.txt /mnt
    echo "paru --noconfirm --needed -S - < aur_packages.txt" | $CHROOT su "${USERS[7]}"
    rm /mnt/aur_packages.txt
}

# Make startx works with awesome
setup_startx() {
    for user in "${USERS[@]}";
    do
        echo "cp /etc/X11/xinit/xinitrc ~/.xinitrc &&
        head -n -5 ~/.xinitrc > ~/temp &&
        echo 'exec awesome' >> ~/temp &&
        mv ~/temp ~/.xinitrc" | $CHROOT su "$user"
    done
}

setup_default_apps() {
    for user in "${USERS[@]}";
    do
        echo "xdg-mime default org.pwmt.zathura.desktop application/pdf &&
            xdg-mime default zen.desktop x-scheme-handler/https &&
        xdg-mime default zen.desktop x-scheme-handler/http" | $CHROOT su "$user"
    done
}

dotfiles() {
    for user in root "${USERS[@]}";
    do
        echo "cd ~/ &&
        git clone https://github.com/guilhermedasilvavieira/.dotfiles &&
        .dotfiles/install.sh" | $CHROOT su "$user"
    done
}

setup_gtk() {
    for user in "${USERS[@]}";
    do
        $CHROOT gsettings set org.gnome.desktop.interface gtk-theme "Nordic-bluish-accent"
        $CHROOT gsettings set org.gnome.desktop.interface icon-theme "Tela circle orange dark"
        $CHROOT gsettings set org.gnome.desktop.interface cursors-theme "Nordzy-cursors"
    done
}

setup_searxng() {
    echo "cd /usr/local &&
    git clone https://github.com/searxng/searxng-docker.git &&
    cd searxng-docker &&
    sed -i "s|ultrasecretkey|$(openssl rand -hex 32)|g" searxng/settings.yml &&
    sed -i '/^\s*cap_drop:/s/^/# /' docker-compose.yaml &&
    sed -i '/^\s*- ALL/s/^/# /' docker-compose.yaml &&
    docker compose up -d" | $CHROOT

    echo " cd /usr/local/searxng-docker/
    sed 's/#/ /g' docker-compose.yaml &&
    cp searxng-docker.service.template searxng-docker.service &&
    systemctl enable $(pwd)/searxng-docker.service" | $CHROOT
}

isolate_user_only_packages() {
    # Nami
    echo "groupadd nami_only &&
    usermod -aG nami_only nami &&
    chown root:nami_only /bin/tradingview &&
    chmod 750 /bin/tradingview" | $CHROOT

    # Robin
    echo "groupadd robin_only &&
    usermod -aG robin_only robin &&
    chown root:robin_only /bin/obsidian /usr/share/applications/obsidian.desktop &&
    chmod 750 /bin/obsidian /usr/share/applications/obsidian.desktop" | $CHROOT

    # Franky
    echo "groupadd franky_only &&
    usermod -aG franky_only franky &&
    chown root:franky_only /bin/lazygit &&
    chmod 750 /bin/lazygit &&
    chown root:franky_only /bin/gitui &&
    chmod 750 /bin/gitui &&
    chown root:franky_only /bin/lldb &&
    chmod 750 /bin/lldb &&
    chown root:franky_only /bin/mise &&
    chmod 750 /bin/mise &&
    chown root:franky_only /bin/rust-analyzer &&
    chmod 750 /bin/rust-analyzer &&
    chown root:franky_only /bin/bash-language-server &&
    chmod 750 /bin/bash-language-server &&
    chown root:franky_only /bin/basedpyright &&
    chmod 750 /bin/basedpyright &&
    chown root:franky_only /bin/basedpyright-langserver &&
    chmod 750 /bin/basedpyright-langserver &&
    chown root:franky_only /bin/ruff &&
    chmod 750 /bin/ruff &&
    chown root:franky_only /bin/black &&
    chmod 750 /bin/black &&
    chown root:franky_only /bin/blackd &&
    chmod 750 /bin/blackd &&
    chown root:franky_only /bin/dnsmasq &&
    chmod 750 /bin/dnsmasq &&
    chown root:franky_only /bin/virt-manager /usr/share/applications/virt-manager.desktop &&
    chmod 750 /bin/virt-manager /usr/share/applications/virt-manager.desktop &&
    chown root:franky_only /bin/chromium /usr/share/applications/chromium.desktop &&
    chmod 750 /bin/chromium /usr/share/applications/chromium.desktop &&
    chown root:franky_only /bin/android-studio /usr/share/applications/android-studio.desktop &&
    chmod 750 /bin/android-studio /usr/share/applications/android-studio.desktop &&
    chown root:franky_only /bin/code /usr/share/applications/code.desktop &&
    chmod 750 /bin/code /usr/share/applications/code.desktop" | $CHROOT

    # Usopp
    echo "groupadd usopp_only &&
    usermod -aG usopp_only usopp &&
    chown root:usopp_only /bin/ani-cli &&
    chmod 750 /bin/ani-cli && 
    chown root:usopp_only /bin/mangohud &&
    chmod 750 /bin/mangohud && 
    chown root:usopp_only /bin/steam /usr/share/applications/steam.desktop &&
    chmod 750 /bin/steam /usr/share/applications/steam.desktop &&
    chown root:usopp_only /bin/discord /usr/share/applications/discord.desktop &&
    chmod 750 /bin/discord /usr/share/applications/discord.desktop" | $CHROOT
}

is_uefi
cleanup
disks
# Change Keyboard
loadkeys br-abnt2
# Install system foundation
pacstrap -K /mnt base linux linux-firmware linux-headers
# Permanent mount partitions
genfstab -U /mnt >> /mnt/etc/fstab
time_and_locale
# Set console keyboard to br
echo 'KEYMAP=br-abnt2' >> /mnt/etc/vconsole.conf
# Host name
echo $HOST >> /mnt/etc/hostname
packages
# Only the group wheel has superuser permission
echo 'permit keepenv persist :wheel' >> /mnt/etc/doas.conf
# Change shell to fish
$CHROOT chsh -s /bin/fish
bootloader
create_user
systems
zram
# Root password
echo root:$PASSWORD >> passwords.txt
# User Passowrds
cp -v passwords.txt /mnt
$CHROOT chpasswd < passwords.txt
rm /mnt/passwords.txt
# Set stable rust
$CHROOT mise use --global rust@
aur
# Change keyboard to br
cat >> /mnt/etc/X11/xorg.conf.d/00-keyboard.conf <<EOL
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "br"
EndSection
EOL
setup_startx
setup_default_apps
dotfiles
setup_gtk
setup_searxng
isolate_user_only_packages
$CHROOT mkinitcpio -P
# Save any logs
cp -v "*.log" /mnt
reboot
