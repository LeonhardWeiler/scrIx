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
DISK_SIZE=$(lsblk -d -n -o SIZE /dev/${DISKS[$disk_choice]})
DISK_SIZE_MB=$(echo $DISK_SIZE | sed 's/[A-Za-z]*//g' | awk '{print $1 * 1024}')
echo "Gewählte Festplatte: $DISK (Größe: $DISK_SIZE)"

# RAM-Größe ermitteln
RAM_SIZE=$(free -h | grep Mem | awk '{print $2}')
RAM_SIZE_MB=$(echo $RAM_SIZE | sed 's/[A-Za-z]*//g' | awk '{print $1 * 1024}')
echo "Gesamte RAM-Größe: $RAM_SIZE (in MB: $RAM_SIZE_MB)"

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

# Neues GPT-Label setzen
echo "Setze neues GPT-Label auf $DISK..."
parted "$DISK" --script mklabel gpt
echo "Neues GPT-Label gesetzt."

# Partitionen manuell auswählen
while true; do
    # Anzeige der verfügbaren Größen
    echo "Gesamte Festplattengröße: $DISK_SIZE_MB MB"
    echo "Empfohlene maximale Größe für Swap-Partition: $RAM_SIZE_MB MB (1x RAM wird empfohlen)"

    read -p "Gib die Größe der Swap-Partition an (z. B. 16G): " swap_size
    swap_size_mb=$(echo $swap_size | sed 's/[A-Za-z]*//g')

    if [[ -z "$swap_size" ]] || ! [[ "$swap_size" =~ ^[0-9]+[MG]?$ ]]; then
        echo "Ungültige Eingabe, bitte eine gültige Größe für die Swap-Partition angeben (z. B. 16G oder 1024M)."
        continue
    fi

    # Überprüfen, ob Swap innerhalb der Grenzen liegt
    if (( swap_size_mb > RAM_SIZE_MB )); then
        echo "Swap-Partition kann nicht größer als die RAM-Größe sein."
        continue
    fi

    if (( swap_size_mb > DISK_SIZE_MB )); then
        echo "Die Swap-Partition ist größer als die Festplatte. Bitte kleinere Werte wählen."
        continue
    fi

    break
done

# Root- und Home-Partitionen auswählen
while true; do
    read -p "Gib die Größe der Root-Partition an (z. B. 100G): " root_size
    root_size_mb=$(echo $root_size | sed 's/[A-Za-z]*//g')

    if [[ -z "$root_size" ]] || ! [[ "$root_size" =~ ^[0-9]+[MG]?$ ]]; then
        echo "Ungültige Eingabe, bitte eine gültige Größe für die Root-Partition angeben."
        continue
    fi

    read -p "Gib die Größe der Home-Partition an (z. B. 100G): " home_size
    home_size_mb=$(echo $home_size | sed 's/[A-Za-z]*//g')

    if [[ -z "$home_size" ]] || ! [[ "$home_size" =~ ^[0-9]+[MG]?$ ]]; then
        echo "Ungültige Eingabe, bitte eine gültige Größe für die Home-Partition angeben."
        continue
    fi

    # Berechnungen für Gesamtgröße und Überprüfung
    total_size_mb=$(($swap_size_mb + $root_size_mb + $home_size_mb))

    if (( total_size_mb > DISK_SIZE_MB )); then
        echo "Die Gesamtgröße der Partitionen überschreitet die Festplattengröße. Bitte kleinere Werte wählen."
        continue
    fi

    break
done

echo "Festplattenpartitionen: Swap = $swap_size_mb MB, Root = $root_size_mb MB, Home = $home_size_mb MB"

# Partitionieren der Festplatte
echo "Partitioniere $DISK mit GPT..."
parted "$DISK" -- mkpart ESP fat32 1MiB 1025MiB
parted "$DISK" -- set 1 esp on
parted "$DISK" -- name 1 EFI
parted "$DISK" -- mkpart primary 1025MiB $(($swap_size_mb + 1025))MiB
parted "$DISK" -- name 2 swap
parted "$DISK" -- mkpart primary $(($swap_size_mb + 1025))MiB $(($swap_size_mb + $root_size_mb + 1025))MiB
parted "$DISK" -- name 3 root
parted "$DISK" -- mkpart primary $(($swap_size_mb + $root_size_mb + 1025))MiB 100%
parted "$DISK" -- name 4 home

# EFI-Partition formatieren
EFI_PART="${DISK}${PART_SUFFIX}1"
echo "Formatiere EFI-Partition ($EFI_PART)..."
mkfs.fat -F32 -n EFI "$EFI_PART"

# Swap-Partition formatieren
SWAP_PART="${DISK}${PART_SUFFIX}2"
echo "Formatiere Swap-Partition ($SWAP_PART)..."
mkswap "$SWAP_PART"

# Root-Partition formatieren
ROOT_PART="${DISK}${PART_SUFFIX}3"
echo "Formatiere Root-Partition ($ROOT_PART)..."
mkfs.ext4 -L ROOT "$ROOT_PART"

# Home-Partition formatieren
HOME_PART="${DISK}${PART_SUFFIX}4"
echo "Formatiere Home-Partition ($HOME_PART)..."
mkfs.ext4 -L HOME "$HOME_PART"

# LVM einrichten (optional, wenn gewünscht)
# echo "LVM einrichten (optional)..."

# Mounten der Dateisysteme
echo "Mounten der Dateisysteme..."
swapon "$SWAP_PART"
mount "$ROOT_PART" /mnt
mkdir /mnt/home
mount "$HOME_PART" /mnt/home
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# NixOS-Konfiguration generieren
echo "Generiere NixOS-Konfiguration..."
nixos-generate-config --root /mnt

echo "Skript abgeschlossen. Bitte die Konfiguration in /mnt/etc/nixos/configuration.nix anpassen und 'nixos-install' ausführen."

