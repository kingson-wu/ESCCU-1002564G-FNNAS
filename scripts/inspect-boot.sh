#!/usr/bin/env bash
# 只读检查：dump vendor 镜像 boot 分区的 boot.cmd / fnEnv.txt / 文件清单
# 注意：全程避免 `cmd | head` 之类在 pipefail 下会 SIGPIPE 的写法
set -uo pipefail
IMG="$1"
OUT="$2"
mkdir -p "$OUT"
LOOP="$(losetup -Pf --show "$IMG")"
trap 'losetup -d "$LOOP" 2>/dev/null || true' EXIT
sleep 2
lsblk -ln -o NAME,TYPE "$LOOP" || true

for p in $(lsblk -ln -o NAME,TYPE "$LOOP" | awk '$2=="part"{print "/dev/"$1}'); do
    mkdir -p /mnt/p
    if mount -o ro "$p" /mnt/p; then
        f="$OUT/$(basename "$p").txt"
        {
            echo "=== $p ==="
            ls -l /mnt/p
            [[ -f /mnt/p/fnEnv.txt ]] && { echo "--- fnEnv.txt ---"; cat /mnt/p/fnEnv.txt; }
            [[ -f /mnt/p/boot.cmd ]] && { echo "--- boot.cmd ---"; cat /mnt/p/boot.cmd; }
            [[ -f /mnt/p/boot.scr ]] && { echo "--- boot.scr strings ---"; strings /mnt/p/boot.scr; }
            [[ -f /mnt/p/extlinux/extlinux.conf ]] && { echo "--- extlinux.conf ---"; cat /mnt/p/extlinux/extlinux.conf; }
            [[ -d /mnt/p/dtb ]] && { echo "--- dtb names ---"; find /mnt/p/dtb -name 'rk3568*.dtb' -printf '%f\n'; }
        } > "$f" 2>&1
        umount /mnt/p || true
    else
        echo "skip $p (not mountable)" >> "$OUT/mount.log"
    fi
done
tar -czf "$OUT/../bootinfo.tar.gz" -C "$OUT" . || true
ls -l "$OUT/../bootinfo.tar.gz" || true
