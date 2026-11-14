#!/usr/bin/env bash
# 只读检查：把 vendor 镜像 boot 分区的 boot.cmd / fnEnv.txt / 文件名清单 dump 出来
set -euo pipefail
IMG="${1:?img}"
OUT="${2:?outdir}"
mkdir -p "$OUT"
LOOP="$(losetup -Pf --show "$IMG")"
trap 'losetup -d "$LOOP" 2>/dev/null || true' EXIT
sleep 2
lsblk -ln -o NAME,TYPE "$LOOP"
for p in $(lsblk -ln -o NAME,TYPE "$LOOP" | awk '$2=="part"{print "/dev/"$1}'); do
    mkdir -p /mnt/p
    if mount -o ro "$p" /mnt/p 2>/dev/null; then
        {
            echo "=== $p ==="
            ls -l /mnt/p | head -40
            if [[ -f /mnt/p/fnEnv.txt ]]; then echo "--- fnEnv.txt ---"; cat /mnt/p/fnEnv.txt; fi
            if [[ -f /mnt/p/boot.cmd ]]; then echo "--- boot.cmd ---"; cat /mnt/p/boot.cmd; fi
            if [[ -f /mnt/p/boot.scr ]]; then echo "--- boot.scr strings ---"; strings /mnt/p/boot.scr | head -30; fi
            if [[ -f /mnt/p/extlinux/extlinux.conf ]]; then echo "--- extlinux.conf ---"; cat /mnt/p/extlinux/extlinux.conf; fi
        } > "$OUT/$(basename "$p").txt" 2>&1
        umount /mnt/p
    fi
done
ls -l "$OUT"
tar -czf "$OUT/../bootinfo.tar.gz" -C "$OUT" .
