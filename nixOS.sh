#!/bin/bash

set -e

if [[ $EUID -ne 0 ]]; then
    echo "Bitte das Skript als Root ausführen."
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "Das System verwendet kein UEFI. Die Installation wird abgebrochen."
    exit 1
fi

echo "UEFI-Umgebung erkannt. Fortsetzung..."

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

if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [[ "$disk_choice" -ge "${#DISKS[@]}" ]]; then
    echo "Ungültige Auswahl. Abbruch."
    exit 1
fi

DISK="/dev/${DISKS[$disk_choice]}"
DISK_SIZE=$(lsblk -d -n -o SIZE /dev/${DISKS[$disk_choice]})
DISK_SIZE_MB=$(echo $DISK_SIZE | sed 's/[A-Za-z]*//g' | awk '{print $1 * 1024}')
echo "Gewählte Festplatte: $DISK (Größe: $DISK_SIZE)"

RAM_SIZE=$(free -h | grep Mem | awk '{print $2}')
RAM_SIZE_MB=$(echo $RAM_SIZE | sed 's/[A-Za-z]*//g' | awk '{print $1 * 1024}')
echo "Gesamte RAM-Größe: $RAM_SIZE (in MB: $RAM_SIZE_MB)"

ROOT_SIZE=$DISK_SIZE/3
ROOT_SIZE_MB=$DISK_SIZE_MB/3

if [[ $DISK =~ nvme[0-9]n[0-9]$ ]]; then
    PART_SUFFIX="p"
else
    PART_SUFFIX=""
fi

echo "WARNUNG: ALLE DATEN AUF $DISK WERDEN GELÖSCHT."
echo "Methode der Überschreibung wählen:"
echo "0) Mit Nullbytes überschreiben (schnell)"
echo "1) Mit Zufallswerten überschreiben (sicher, aber langsam)"
echo "n) Abbrechen"

read -p "Eingabe: " wipe_choice
case "$wipe_choice" in
    0)
        echo "Überschreibe $DISK mit Nullbytes..."
        dd if=/dev/zero of="$DISK" bs=1M status=progress || true
        ;;
    1)
        echo "Überschreibe $DISK mit Zufallswerten..."
        dd if=/dev/urandom of="$DISK" bs=1M status=progress || true
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

echo "Setze neues GPT-Label auf $DISK..."
parted "$DISK" --script mklabel gpt
echo "Neues GPT-Label gesetzt."

while true; do
    read -p "Gib die Größe der Swap-Partition in GB oder MB an (z. B. ${RAM_SIZE}G): " swap_size

    size_value=$(echo "$swap_size" | sed 's/[A-Za-z]*//g')
    unit=$(echo "$swap_size" | grep -o '[MG]$')

    if [[ -z "$swap_size" ]] || ! [[ "$swap_size" =~ ^[0-9]+[MG]$ ]]; then
        echo "Ungültige Eingabe, bitte eine gültige Größe angeben (z. B. ${RAM_SIZE}G oder ${RAM_SIZE_MB}M)."
        continue
    fi

    if [[ "$unit" == "G" ]]; then
        swap_size_mb=$((size_value * 1024))
    else
        swap_size_mb=$size_value
    fi

    if (( swap_size_mb > RAM_SIZE_MB )); then
        echo "Swap-Partition kann nicht größer als die RAM-Größe sein (${RAM_SIZE_MB} MB)."
        continue
    fi

    if (( swap_size_mb > DISK_SIZE_MB )); then
        echo "Die Swap-Partition ist größer als der verfügbare Festplattenspeicher (${DISK_SIZE_MB} MB). Bitte kleinere Werte wählen."
        continue
    fi

    break
done

while true; do
    read -p "Gib die Größe der Root-Partition an (z. B. ${ROOT_SIZE}G): " root_size

    root_value=$(echo "$root_size" | sed 's/[A-Za-z]*//g')
    root_unit=$(echo "$root_size" | grep -o '[MG]$')

    if [[ -z "$root_size" ]] || ! [[ "$root_size" =~ ^[0-9]+[MG]$ ]]; then
        echo "Ungültige Eingabe, bitte eine gültige Größe für die Root-Partition angeben (z. B. ${ROOT_SIZE}G)."
        continue
    fi

    if [[ "$root_unit" == "G" ]]; then
        root_size_mb=$((root_value * 1024))
    else
        root_size_mb=$root_value
    fi

    remaining_size_mb=$((DISK_SIZE_MB - swap_size_mb - root_size_mb))

    if (( remaining_size_mb <= 0 )); then
        echo "Die Root- und Swap-Partitionen überschreiten bereits die Festplattengröße (${DISK_SIZE_MB} MB)."
        continue
    fi

    read -p "Gib die Größe der Home-Partition an (z. B. 100G oder 'default' für verbleibende ${remaining_size_mb}MB): " home_size

    if [[ "$home_size" == "default" ]]; then
        home_size_mb=$remaining_size_mb
    else
        home_value=$(echo "$home_size" | sed 's/[A-Za-z]*//g')
        home_unit=$(echo "$home_size" | grep -o '[MG]$')

        if [[ -z "$home_size" ]] || ! [[ "$home_size" =~ ^[0-9]+[MG]$ ]]; then
            echo "Ungültige Eingabe, bitte eine gültige Größe für die Home-Partition angeben."
            continue
        fi

        if [[ "$home_unit" == "G" ]]; then
            home_size_mb=$((home_value * 1024))
        else
            home_size_mb=$home_value
        fi
    fi

    total_size_mb=$((swap_size_mb + root_size_mb + home_size_mb))
    if (( total_size_mb > DISK_SIZE_MB )); then
        echo "Die Gesamtgröße der Partitionen ($total_size_mb MB) überschreitet die Festplattengröße (${DISK_SIZE_MB} MB)."
        continue
    fi

    break
done

echo "Partitionierung erfolgreich:"
echo "  Swap-Partition: ${swap_size_mb} MB"
echo "  Root-Partition: ${root_size_mb} MB"
echo "  Home-Partition: ${home_size_mb} MB"

read -sp "LUKS-Passwort eingeben: " luks_password
echo
read -sp "LUKS-Passwort erneut eingeben: " luks_password_confirm
echo

if [[ "$luks_password" != "$luks_password_confirm" ]]; then
    echo "Die eingegebenen Passwörter stimmen nicht überein. Abbruch."
    exit 1
fi

echo "Partitioniere $DISK mit GPT..."
parted "$DISK" -- mkpart ESP fat32 1MiB 1025MiB
parted "$DISK" -- set 1 esp on
parted "$DISK" -- name 1 EFI
parted "$DISK" -- mkpart primary 1025MiB 100%
parted "$DISK" -- name 2 LUKS

EFI_PART="${DISK}${PART_SUFFIX}1"
echo "Formatiere EFI-Partition ($EFI_PART)..."
mkfs.fat -F32 -n EFI "$EFI_PART"

LUKS_PART="${DISK}${PART_SUFFIX}2"
echo "Erstelle und öffne LUKS-Partition ($LUKS_PART)..."
cryptsetup luksFormat --type luks2 "$LUKS_PART"
cryptsetup open "$LUKS_PART" cryptroot

echo "Erstelle LVM-Volumes..."
pvcreate /dev/mapper/cryptroot
vgcreate vg /dev/mapper/cryptroot
lvcreate -L $swap_size_mb -n swap vg
lvcreate -L $root_size_mb -n root vg
lvcreate -l $home_size_mb -n home vg

echo "Formatiere Dateisysteme..."
mkfs.ext4 -L ROOT /dev/vg/root
mkfs.ext4 -L HOME /dev/vg/home
mkswap --label SWAP /dev/vg/swap

echo "Mounten der Dateisysteme..."
swapon /dev/vg/swap
mount LABEL=ROOT /mnt
mkdir /mnt/home
mount LABEL=HOME /mnt/home
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "Generiere NixOS-Konfiguration..."
nixos-generate-config --root /mnt

echo "Skript abgeschlossen. Bitte die Konfiguration in /mnt/etc/nixos/configuration.nix anpassen und 'nixos-install' ausführen."
