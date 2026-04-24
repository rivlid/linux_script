#!/bin/bash
#r.kalsin

set -e

# --- Настройки ---
VM_ID=1000041
VM_NAME="deb13-clin-vm01"
MEMORY=4096
CORES=4
SWAP_SIZE="2G"
DB_SIZE="30G"
SYSTEM_DISK_SIZE="30G"
STORAGE="zfs-ssd"
BRIDGE="vmbr0"
OS_CHOICE="debian13"
CLOUDINIT_USER="root"
CLOUDINIT_PASS="rootpass"
CREATE_DB_DISK=false          # <-- false если диск db не нужен
TEMP_DIR="./tmp_vm_template_$VM_ID"

# определяем стартовый каталог
START_DIR=$(pwd)

# --- Проверки ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: нужен root!" >&2
    exit 1
fi

if qm status $VM_ID >/dev/null 2>&1; then
    echo "Ошибка: ВМ с ID $VM_ID уже существует!" >&2
    exit 1
fi

if ! command -v guestfish &> /dev/null; then
    echo "Установка libguestfs-tools..."
    apt update && apt install -y libguestfs-tools
fi

# Создаем временную директорию
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# --- Очистка при ошибке ---
cleanup() {
    cd "$START_DIR"
    rm -rf "$TEMP_DIR"
    qm destroy "$VM_ID" --purge 2>/dev/null || true
}
trap cleanup ERR

# --- Выбор ОС ---
case "$OS_CHOICE" in
    debian12)
        IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
        IMAGE_NAME="debian-12-generic-amd64.qcow2"
        ;;
    debian13)
        IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
        IMAGE_NAME="debian-13-generic-amd64.qcow2"
        ;;
    *)
        echo "Неизвестная ОС: $OS_CHOICE" >&2
        exit 1
        ;;
esac

# --- Загрузка образа ОС ---
if [ ! -f "$IMAGE_NAME" ]; then
    echo "Загрузка образа ОС..."
    wget "$IMAGE_URL" -O "$IMAGE_NAME"
fi

# --- Создание swap-диска ---
echo "[1/10] Создание и подготовка swap-диска..."
qemu-img create -f qcow2 swapdisk.qcow2 "$SWAP_SIZE"

guestfish -a swapdisk.qcow2 <<EOF
run
mkswap /dev/sda
EOF

SWAP_UUID=$(guestfish --ro -a swapdisk.qcow2 -- run : get-uuid /dev/sda)
echo "Swap UUID: $SWAP_UUID"

if [ -z "$SWAP_UUID" ]; then
    echo "Ошибка: не удалось получить UUID swap!" >&2
    exit 1
fi

# --- Создание диска для базы данных ---
if [ "$CREATE_DB_DISK" = true ]; then
    echo "[2/10] Создание диска для базы данных Firebird..."
    qemu-img create -f qcow2 fbdatabase.qcow2 "$DB_SIZE"

    guestfish -a fbdatabase.qcow2 <<EOF
run
part-init /dev/sda mbr
part-add /dev/sda primary 2048 -1
mkfs ext4 /dev/sda1
EOF

    DB_UUID=$(guestfish --ro -a fbdatabase.qcow2 -- run : vfs-uuid /dev/sda1)
    echo "DB UUID: $DB_UUID"

    if [ -z "$DB_UUID" ]; then
        echo "Ошибка: не удалось получить UUID db-диска!" >&2
        exit 1
    fi
else
    echo "[2/10] Пропуск создания db-диска (CREATE_DB_DISK=false)..."
fi

# --- Настройка основного образа ---
echo "[3/10] Настройка основного диска..."

# Базовые команды настройки
VIRT_CUSTOMIZE_CMD=(virt-customize -a "$IMAGE_NAME"
    --install qemu-guest-agent,vim,htop
    --run-command 'echo -n > /etc/machine-id'
    --run-command 'ln -fs /etc/machine-id /var/lib/dbus/machine-id'
    --run-command 'rm -rf /var/lib/cloud/*'
    --update
    --run-command "apt clean && rm -rf /var/lib/apt/lists/*"
    --run-command "ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime && echo 'Europe/Moscow' > /etc/timezone"
    --run-command "mkdir -p /mnt/backup"
    # Убираем EFI раздел из fstab
    --run-command "sed -i '/\\/boot\\/efi/d' /etc/fstab"
    # Добавляем swap в fstab
    --run-command "echo 'UUID=$SWAP_UUID none swap sw 0 0' >> /etc/fstab"
)

# Добавляем db в fstab только если нужно
if [ "$CREATE_DB_DISK" = true ]; then
    VIRT_CUSTOMIZE_CMD+=(
        --run-command "mkdir -p /mnt/db"
        --run-command "echo 'UUID=$DB_UUID /mnt/db ext4 defaults 0 2' >> /etc/fstab"
    )
fi

"${VIRT_CUSTOMIZE_CMD[@]}"

# --- Создание ВМ ---
echo "[4/10] Создание ВМ $VM_ID..."
qm create "$VM_ID" \
    --name "$VM_NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio,bridge="$BRIDGE"

# --- Импорт основного диска ---
echo "[5/10] Импорт основного диска..."
qm importdisk "$VM_ID" "$IMAGE_NAME" "$STORAGE" --format qcow2
qm set "$VM_ID" \
    --scsihw virtio-scsi-pci \
    --scsi0 "$STORAGE:vm-$VM_ID-disk-0"
qm resize "$VM_ID" scsi0 "$SYSTEM_DISK_SIZE"

# --- Импорт swap-диска ---
echo "[6/10] Импорт swap-диска..."
qm importdisk "$VM_ID" swapdisk.qcow2 "$STORAGE" --format qcow2
qm set "$VM_ID" --scsi2 "$STORAGE:vm-$VM_ID-disk-1"

# --- Импорт диска db ---
if [ "$CREATE_DB_DISK" = true ]; then
    echo "[7/10] Импорт db-диска..."
    qm importdisk "$VM_ID" fbdatabase.qcow2 "$STORAGE" --format qcow2
    qm set "$VM_ID" --scsi3 "$STORAGE:vm-$VM_ID-disk-2"
else
    echo "[7/10] Пропуск импорта db-диска (CREATE_DB_DISK=false)..."
fi

# --- Cloud-Init и финальная настройка ---
echo "[8/10] Настройка Cloud-Init..."
qm set "$VM_ID" \
    --ide2 "$STORAGE:cloudinit" \
    --boot c --bootdisk scsi0 \
    --agent 1 \
    --serial0 socket --vga serial0 \
    --ciuser "$CLOUDINIT_USER" \
    --cipassword "$CLOUDINIT_PASS" \
    --ipconfig0 ip=dhcp

# --- Преобразуем в шаблон ---
echo "[9/10] Преобразование в шаблон..."
qm template "$VM_ID"

# --- Очистка ---
echo "[10/10] Очистка временных файлов..."
trap - ERR
cd "$START_DIR"
rm -rf "$TEMP_DIR"

echo "Готово! Шаблон $VM_ID успешно создан."
