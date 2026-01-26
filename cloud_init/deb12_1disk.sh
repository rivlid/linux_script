#!/bin/bash
#rivlid

set -e

# --- Настройки ---
VM_ID=100093
VM_NAME="infrax"
MEMORY=4096
CORES=4
SWAP_SIZE="2G"
SYSTEM_DISK_SIZE="40G"
STORAGE="zfs-ssd"
BRIDGE="vmbr0"
OS_CHOICE="debian12"
CLOUDINIT_USER="root"
CLOUDINIT_PASS="rootpass"
TIMEZONE="Europe/Moscow"

# --- Проверки ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: нужен root!" >&2
    exit 1
fi

# Проверяем, существует ли уже ВМ с таким ID
if qm status $VM_ID >/dev/null 2>&1; then
    echo "Ошибка: ВМ с ID $VM_ID уже существует!" >&2
    exit 1
fi

# Проверяем установлен ли guestfish
if ! command -v guestfish &> /dev/null; then
    echo "Установка libguestfs-tools..."
    apt update && apt install -y libguestfs-tools
fi

# --- Выбор ОС ---
case "$OS_CHOICE" in
    debian12)
        IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
        IMAGE_NAME="debian-12-generic-amd64.qcow2"
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
echo "[1/5] Создание и подготовка swap-диска..."
qemu-img create -f qcow2 swapdisk.qcow2 "$SWAP_SIZE"

echo "Создание swap..."
guestfish -a swapdisk.qcow2 <<EOF
run
mkswap /dev/sda
EOF
echo "Done"

# --- Получение UUID swap-диска ---
echo "Получение UUID..."
SWAP_UUID=$(guestfish --ro -a swapdisk.qcow2 <<EOF | grep 'UUID:' | awk '{print $2}'
run
blkid /dev/sda
EOF
)
echo "Done: $SWAP_UUID"

# --- Настройка основного образа ---
echo "[2/5] Настройка основного диска..."
virt-customize -a "$IMAGE_NAME" \
    --install qemu-guest-agent,vim,htop \
    --run-command 'echo -n > /etc/machine-id' \
    --run-command 'ln -fs /etc/machine-id /var/lib/dbus/machine-id' \
    --run-command 'rm -rf /var/lib/cloud/*' \
    --timezone "$TIMEZONE" \
    --update \
    --run-command "apt clean && rm -rf /var/lib/apt/lists/*" \
    --run-command "echo 'UUID=$SWAP_UUID none swap sw 0 0' >> /etc/fstab"

# --- Создание ВМ ---
echo "[3/5] Создание ВМ $VM_ID..."
qm create "$VM_ID" \
    --name "$VM_NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --cpu host \
    --net0 virtio,bridge="$BRIDGE"

# --- Импорт основного диска ---
echo "[4/5] Импорт основного диска..."
qm importdisk "$VM_ID" "$IMAGE_NAME" "$STORAGE" --format qcow2
qm set "$VM_ID" \
    --scsihw virtio-scsi-pci \
    --scsi0 "$STORAGE:vm-$VM_ID-disk-0"
qm resize "$VM_ID" scsi0 "$SYSTEM_DISK_SIZE"

# --- Импорт swap-диска ---
echo "[5/5] Импорт swap-диска..."
qm importdisk "$VM_ID" swapdisk.qcow2 "$STORAGE" --format qcow2
qm set "$VM_ID" --scsi1 "$STORAGE:vm-$VM_ID-disk-1"

# --- Cloud-Init, Boot и финальная настройка ---
    qm set "$VM_ID" \
        --ide2 "$STORAGE:cloudinit" \
        --boot c --bootdisk scsi0 \
        --agent 1 \
        --serial0 socket --vga serial0 \
        --ciuser "$CLOUDINIT_USER" \
        --cipassword "$CLOUDINIT_PASS" \
        --ipconfig0 ip=dhcp


# --- Преобразуем в шаблон ---
qm template "$VM_ID"

# --- Очистка ---
rm -f "$IMAGE_NAME" swapdisk.qcow2

echo "✅ Готово! Шаблон $VM_ID успешно создан."
