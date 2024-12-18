#!/bin/bash

set -e

# Sicherstellen, dass das Skript als Root ausgeführt wird
if [[ $EUID -ne 0 ]]; then
    echo "Bitte das Skript als Root ausführen."
    exit 1
fi

# Prüfen, ob UEFI verwendet wird
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "Das System verwendet kein UEFI. Die Installation wird abgebrochen."
    exit 1
fi

echo "UEFI-Umgebung erkannt. Fortsetzung..."

# WLAN-Setup (optional)
read -p "WLAN verwenden? (y/n): " use_wifi
if [[ "$use_wifi" == "y" ]]; then
    echo "WLAN-Setup wird gestartet..."
    systemctl start wpa_supplicant
    wpa_cli <<EOF
add_network
set_network 0 ssid "$(read -p 'SSID: ' ssid && echo $ssid)"
set_network 0 psk "$(read -sp 'Passwort: ' psk && echo $psk)"
enable_network 0
quit
EOF
    echo "WLAN konfiguriert."
fi

# Festplatten erkennen und zur Auswahl anzeigen
echo "Verfügbare Festplatten:"
lsblk -d -n -o NAME,SIZE,TYPE | grep disk

read -p "Gib die Festplatte an, auf der NixOS installiert werden soll (z.B. 'sda', 'nvme0n1'): " DISK
DISK="/dev/$DISK"

if [[ ! -b "$DISK" ]]; then
    echo "Ungültige Festplatte: $DISK. Abbruch."
    exit 1
fi

echo "Gewählte Festplatte: $DISK"

# Benutzerwarnung vor Datenverlust
read -p "WARNUNG: ALLE DATEN AUF $DISK WERDEN GELÖSCHT. Fortfahren? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "Installation abgebrochen."
    exit 1
fi

# Alte Partitionen entfernen
echo "Entferne vorhandene Partitionen auf $DISK..."
wipefs -a "$DISK"
parted "$DISK" --script mklabel gpt
echo "Partitionen gelöscht und neues GPT-Label gesetzt."

# LUKS-Passwort abfragen
read -sp "LUKS-Passwort eingeben: " luks_password
echo
read -sp "LUKS-Passwort erneut eingeben: " luks_password_confirm
echo

if [[ "$luks_password" != "$luks_password_confirm" ]]; then
    echo "Die eingegebenen Passwörter stimmen nicht überein. Abbruch."
    exit 1
fi

# Partitionieren der Festplatte
echo "Partitioniere $DISK mit GPT..."
parted "$DISK" -- mkpart ESP fat32 1MiB 1025MiB
parted "$DISK" -- set 1 esp on
parted "$DISK" -- name 1 EFI
parted "$DISK" -- mkpart primary 1025MiB 100%
parted "$DISK" -- name 2 LUKS

# EFI-Partition formatieren
echo "Formatiere EFI-Partition..."
mkfs.fat -F32 -n EFI "${DISK}p1"

# LUKS-Partition einrichten
echo "Erstelle und öffne LUKS-Partition..."
echo -n "$luks_password" | cryptsetup luksFormat --type luks2 --label CRYPT --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${DISK}p2" -
echo -n "$luks_password" | cryptsetup open "${DISK}p2" cryptroot -

# LVM einrichten
echo "Erstelle LVM-Volumes..."
pvcreate /dev/mapper/cryptroot
vgcreate vg /dev/mapper/cryptroot
lvcreate -L 16G -n swap vg
lvcreate -L 100G -n root vg
lvcreate -l 100%FREE -n home vg

# Dateisysteme formatieren
echo "Formatiere Dateisysteme..."
mkfs.ext4 -L ROOT /dev/vg/root
mkfs.ext4 -L HOME /dev/vg/home
mkswap --label SWAP /dev/vg/swap

# Mounten der Dateisysteme
echo "Mounten der Dateisysteme..."
swapon /dev/vg/swap
mount LABEL=ROOT /mnt
mkdir /mnt/home
mount LABEL=HOME /mnt/home
mkdir -p /mnt/boot
mount /dev/disk/by-label/EFI /mnt/boot

# NixOS-Konfiguration generieren
echo "Generiere NixOS-Konfiguration..."
nixos-generate-config --root /mnt

echo "Skript abgeschlossen. Bitte die Konfiguration in /mnt/etc/nixos/configuration.nix anpassen und 'nixos-install' ausführen."

