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

# Festplatten erkennen und zur Auswahl anzeigen
echo "Verfügbare Festplatten:"
DISKS=($(lsblk -d -n -o NAME | grep -v loop))
for i in "${!DISKS[@]}"; do
    echo "$i) ${DISKS[$i]} ($(lsblk -d -n -o SIZE /dev/${DISKS[$i]}))"
done

read -p "Wähle die Festplatte aus (Zahl eingeben, n für Abbruch): " disk_choice
if [[ "$disk_choice" == "n" ]]; then
    echo "Installation abgebrochen."
    exit 1
fi

# Prüfen, ob die Auswahl gültig ist
if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [[ "$disk_choice" -ge "${#DISKS[@]}" ]]; then
    echo "Ungültige Auswahl. Abbruch."
    exit 1
fi

DISK="/dev/${DISKS[$disk_choice]}"
echo "Gewählte Festplatte: $DISK"

# Suffix für Partitionen bestimmen
if [[ $DISK =~ nvme[0-9]n[0-9]$ ]]; then
    PART_SUFFIX="p"  # NVMe verwendet "p" für Partitionen (z. B. nvme0n1p1)
else
    PART_SUFFIX=""   # SATA und Virtio verwenden keinen zusätzlichen Suffix (z. B. sda1)
fi

# Benutzerwarnung vor Datenverlust und Auswahl der Überschreibungsmethode
echo "WARNUNG: ALLE DATEN AUF $DISK WERDEN GELÖSCHT."
echo "Methode der Überschreibung wählen:"
echo "0) Mit Nullbytes überschreiben (schnell)"
echo "1) Mit Zufallswerten überschreiben (sicher, aber langsam)"
echo "n) Abbrechen"

read -p "Eingabe: " wipe_choice
case "$wipe_choice" in
    0)
        echo "Überschreibe $DISK mit Nullbytes..."
        dd if=/dev/zero of="$DISK" bs=1M status=progress
        ;;
    1)
        echo "Überschreibe $DISK mit Zufallswerten..."
        dd if=/dev/urandom of="$DISK" bs=1M status=progress
        ;;
    n)
        echo "Installation abgebrochen."
        exit 1
        ;;
    *)
        echo "Ungültige Eingabe. Abbruch."
        exit 1
        ;;
esac

# Neues GPT-Label setzen
echo "Setze neues GPT-Label auf $DISK..."
parted "$DISK" --script mklabel gpt
echo "Neues GPT-Label gesetzt."

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
EFI_PART="${DISK}${PART_SUFFIX}1"
echo "Formatiere EFI-Partition ($EFI_PART)..."
mkfs.fat -F32 -n EFI "$EFI_PART"

# LUKS-Partition einrichten
LUKS_PART="${DISK}${PART_SUFFIX}2"
echo "Erstelle und öffne LUKS-Partition ($LUKS_PART)..."
cryptsetup luksFormat --type luks2 "$LUKS_PART"
cryptsetup open "$LUKS_PART" cryptroot

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
mount "$EFI_PART" /mnt/boot

# NixOS-Konfiguration generieren
echo "Generiere NixOS-Konfiguration..."
nixos-generate-config --root /mnt

echo "Skript abgeschlossen. Bitte die Konfiguration in /mnt/etc/nixos/configuration.nix anpassen und 'nixos-install' ausführen."

