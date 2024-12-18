#!/bin/bash

set -euo pipefail

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

while true; do
    read -p "Wähle die Festplatte aus (Zahl eingeben, 'n' für Abbruch): " disk_choice
    if [[ "$disk_choice" == "n" ]]; then
        echo "Installation abgebrochen."
        exit 1
    fi
    if [[ "$disk_choice" =~ ^[0-9]+$ ]] && [[ "$disk_choice" -lt "${#DISKS[@]}" ]]; then
        DISK="/dev/${DISKS[$disk_choice]}"
        DISK_SIZE=$(lsblk -d -n -o SIZE "$DISK")
        DISK_SIZE_MB=$(lsblk -d -n -b -o SIZE "$DISK" | awk '{print $1 / 1024 / 1024}')
        echo "Gewählte Festplatte: $DISK (Größe: $DISK_SIZE, ${DISK_SIZE_MB}MB)"
        break
    else
        echo "Ungültige Auswahl. Bitte erneut versuchen."
    fi
done

RAM_SIZE=$(free -h | awk '/^Mem:/ {print $2}')
RAM_SIZE_MB=$(free -m | awk '/^Mem:/ {print $2}')

ROOT_SIZE=$(awk "BEGIN {print $DISK_SIZE_MB / 3 / 1024}")
ROOT_SIZE_MB=$(awk "BEGIN {print $DISK_SIZE_MB / 3}")

if [[ $DISK =~ nvme[0-9]n[0-9]$ ]]; then
    PART_SUFFIX="p"
else
    PART_SUFFIX=""
fi

echo "WARNUNG: ALLE DATEN AUF $DISK WERDEN GELÖSCHT."
echo "Wähle die Methode zur Überschreibung der Festplatte:"
echo "0) Mit Nullbytes überschreiben (schnell)"
echo "1) Mit Zufallswerten überschreiben (sicher, aber langsamer)"
echo "n) Abbrechen"

while true; do
    read -p "Eingabe: " wipe_choice
    case "$wipe_choice" in
        0)
            echo "Überschreibe $DISK mit Nullbytes..."
            dd if=/dev/zero of="$DISK" bs=1M status=progress conv=fsync || {
                echo "Überschreibung mit Nullbytes abgeschlossen (Speicherplatz möglicherweise erschöpft)."
            }
            break
            ;;
        1)
            echo "Überschreibe $DISK mit Zufallswerten..."
            dd if=/dev/urandom of="$DISK" bs=1M status=progress conv=fsync || {
                echo "Überschreibung mit Zufallswerten abgeschlossen (Speicherplatz möglicherweise erschöpft)."
            }
            break
            ;;
        n)
            echo "Installation abgebrochen."
            exit 1
            ;;
        *)
            echo "Ungültige Eingabe. Bitte 0, 1 oder n eingeben."
            ;;
    esac
done

echo "Setze neues GPT-Label auf $DISK..."
parted "$DISK" --script mklabel gpt || {
    echo "Fehler beim Setzen des GPT-Labels."
    exit 1
}
echo "Neues GPT-Label erfolgreich gesetzt."

validate_size_input() {
    local input="$1"
    if [[ -z "$input" ]] || ! [[ "$input" =~ ^[0-9]+[MG]$ ]]; then
        echo "Ungültige Eingabe. Bitte eine Größe mit einer Zahl gefolgt von 'M' oder 'G' angeben (z.B. 4G oder 2048M)."
        return 1
    fi
    return 0
}

convert_to_mb() {
    local size="$1"
    local value="${size%[MG]}"
    local unit="${size: -1}"
    if [[ "$unit" == "G" ]]; then
        echo $((value * 1024))
    else
        echo "$value"
    fi
}

while true; do
    read -p "Gib die Größe der Swap-Partition in G oder M an (z.B. ${RAM_SIZE}G): " swap_size

    if validate_size_input "$swap_size"; then
        swap_size_mb=$(convert_to_mb "$swap_size")
        if (( swap_size_mb > RAM_SIZE_MB )); then
            echo "Swap-Partition kann nicht größer als die RAM-Größe sein (${RAM_SIZE_MB}M)."
            continue
        fi
        if (( swap_size_mb > DISK_SIZE_MB )); then
            echo "Die Swap-Partition ist größer als der verfügbare Festplattenspeicher (${DISK_SIZE_MB}M)."
            continue
        fi
        break
    fi
done

while true; do
    read -p "Gib die Größe der Root-Partition in G oder M an (z.B. ${ROOT_SIZE}G): " root_size

    if validate_size_input "$root_size"; then
        root_size_mb=$(convert_to_mb "$root_size")
        remaining_size_mb=$((DISK_SIZE_MB - swap_size_mb - root_size_mb))

        if (( remaining_size_mb <= 0 )); then
            echo "Die Root- und Swap-Partitionen überschreiten die Festplattengröße (${DISK_SIZE_MB}M)."
            continue
        fi

        while true; do
            read -p "Gib die Größe der Home-Partition in G oder M an oder 'default' für verbleibende ${remaining_size_mb}M: " home_size

            if [[ "$home_size" == "default" ]]; then
                home_size_mb=$remaining_size_mb
            else
                if validate_size_input "$home_size"; then
                    home_size_mb=$(convert_to_mb "$home_size")
                else
                    continue
                fi
            fi

            total_size_mb=$((swap_size_mb + root_size_mb + home_size_mb))
            if (( total_size_mb > DISK_SIZE_MB )); then
                echo "Die Gesamtgröße der Partitionen (${total_size_mb}M) überschreitet die Festplattengröße (${DISK_SIZE_MB}M)."
                continue
            fi
            break
        done
        break
    fi
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
