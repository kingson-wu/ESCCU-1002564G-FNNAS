#!/usr/bin/env bash
# ==========================================================================
# 把自编内核包(6.x.xx-rockchip.tar.gz 里的 boot/dtb/modules/headers) 烤进
# 官方 FnNAS rockchip 整机镜像，产出可直接写入设备的一体化镜像。
#
# 用法：
#   sudo ./build-full-image.sh <官方镜像.img> <内核包解包目录> <输出目录>
# ==========================================================================
set -euo pipefail

IMG="${1:?用法: build-full-image.sh <img> <pkgdir> <outdir>}"
PKG="${2:?缺少内核包解包目录}"
OUT="${3:?缺少输出目录}"
DTB_NAME="rk3568-firefly-aioj.dtb"

[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }
for t in losetup mount xz tar; do command -v "$t" >/dev/null || { echo "缺少 $t"; exit 1; }; done

mkdir -p "$OUT"
LOOP=""
R=""; B=""
cleanup() {
    set +e
    [[ -n "$B" ]] && mountpoint -q "$B" && umount "$B"
    [[ -n "$R" ]] && mountpoint -q "$R" && umount "$R"
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# ---------- 1) 挂载并识别分区 ----------
echo "==> losetup -P $IMG"
LOOP="$(losetup -Pf --show "$IMG")"
sleep 2
parts="$(lsblk -ln -o NAME,TYPE "$LOOP" | awk '$2=="part"{print "/dev/"$1}')"
echo "    分区: ${parts:-none}"

mkdir -p /mnt/probe /mnt/root /mnt/boot
ROOT_PART=""; BOOT_PART=""
for p in $parts; do
    if mount -o rw "$p" /mnt/probe 2>/dev/null; then
        if [[ -d /mnt/probe/etc && -d /mnt/probe/usr ]]; then
            ROOT_PART="$p"
            echo "    rootfs: $p"
        elif [[ -d /mnt/probe/extlinux || -f /mnt/probe/armbianEnv.txt || -d /mnt/probe/dtb ]]; then
            BOOT_PART="$p"
            echo "    boot:   $p"
        fi
        umount /mnt/probe
    fi
done
[[ -n "$ROOT_PART" ]] || { echo "!! 找不到 rootfs 分区"; exit 1; }

R=/mnt/root
mount -o rw "$ROOT_PART" "$R"
if [[ -n "$BOOT_PART" ]]; then
    B=/mnt/boot
    mount -o rw "$BOOT_PART" "$B"
else
    B="$R/boot"
fi
echo "    rootfs -> $R, boot -> $B"

# ---------- 2) 内核 ----------
boottar="$(ls "$PKG"/boot-rockchip-*.tar.gz | head -1)"
dtbtar="$(ls "$PKG"/dtb-rockchip-*.tar.gz | head -1)"
modtar="$(ls "$PKG"/modules-rockchip-*.tar.gz | head -1)"
hdrtar="$(ls "$PKG"/header-rockchip-*.tar.gz | head -1)"

echo "==> 写入 /boot（vmlinuz / uInitrd / System.map / config / initrd）"
tar -xzf "$boottar" -C "$B"
ls -lh "$B" | grep -E "vmlinuz|uInitrd|System.map|config-|initrd" || true

echo "==> 写入 /boot/dtb/rockchip/"
mkdir -p "$B/dtb/rockchip"
tar -xzf "$dtbtar" -C "$B/dtb/rockchip"
[[ -f "$B/dtb/rockchip/$DTB_NAME" ]] || { echo "!! 本板 dtb 未落在 /boot/dtb/rockchip"; exit 1; }
echo "    dtb 总数: $(find "$B/dtb/rockchip" -name '*.dtb' | wc -l)"

echo "==> 写入 /usr/lib/modules"
mkdir -p "$R/usr/lib/modules"
tar -xzf "$modtar" -C "$R/usr/lib/modules"
ver="$(ls "$R/usr/lib/modules" | grep -E "6\.[0-9]+\.[0-9]+" | head -1)"
echo "    模块目录: /usr/lib/modules/$ver"
[[ -d "$R/usr/lib/modules/$ver/kernel" ]] || { echo "!! 模块目录缺少 kernel/"; exit 1; }
[[ -f "$R/usr/lib/modules/$ver/modules.dep" ]] || echo "    warn: 无 modules.dep"

echo "==> 写入 /usr/src headers"
mkdir -p "$R/usr/src"
tar -xzf "$hdrtar" -C "$R/usr/src" || echo "    warn: headers 解包失败（不影响启动）"

# ---------- 3) 启动配置指向本板 dtb ----------
changed=0
for base in "$B" "$R/boot"; do
    [[ -d "$base" ]] || continue
    if [[ -f "$base/extlinux/extlinux.conf" ]]; then
        cp -f "$base/extlinux/extlinux.conf" "$base/extlinux/extlinux.conf.bak" || true
        sed -i -E "s|^(\s*)fdt\s.*|\1fdt /dtb/rockchip/$DTB_NAME|" "$base/extlinux/extlinux.conf"
        if ! grep -q "$DTB_NAME" "$base/extlinux/extlinux.conf"; then
            printf '\nfdt /dtb/rockchip/%s\n' "$DTB_NAME" >> "$base/extlinux/extlinux.conf"
        fi
        echo "    extlinux.conf -> fdt /dtb/rockchip/$DTB_NAME"
        grep -nE 'fdt|linux |append' "$base/extlinux/extlinux.conf" | head -6 || true
        changed=1
    fi
    if [[ -f "$base/armbianEnv.txt" ]]; then
        sed -i -E "s|^\s*fdtfile=.*|fdtfile=rockchip/$DTB_NAME|" "$base/armbianEnv.txt"
        grep -q "fdtfile=" "$base/armbianEnv.txt" || printf 'fdtfile=rockchip/%s\n' "$DTB_NAME" >> "$base/armbianEnv.txt"
        echo "    armbianEnv.txt -> fdtfile=rockchip/$DTB_NAME"
        changed=1
    fi
done
[[ $changed -eq 1 ]] || echo "!! 未找到 extlinux.conf / armbianEnv.txt"

sync

# ---------- 4) 报告 ----------
{
    echo "kernel modules dir: /usr/lib/modules/$ver"
    echo "dtb: $DTB_NAME present at /boot/dtb/rockchip"
    echo "vmlinuz: $(ls "$B" | grep vmlinuz | head -1)"
    echo "uInitrd: $(ls "$B" | grep uInitrd | head -1)"
    echo "modules groups: $(ls "$R/usr/lib/modules/$ver/kernel" 2>/dev/null | wc -l)"
} | tee "$OUT/report.txt"

cleanup
trap - EXIT

# ---------- 5) 压缩 ----------
OUT_IMG="$OUT/FnNAS-AIO3568J-${ver}.img"
mv "$IMG" "$OUT_IMG"
echo "==> 压缩（xz -9 -T2，耗时较久）"
xz -9 -T2 -c "$OUT_IMG" > "${OUT_IMG}.xz"
rm -f "$OUT_IMG"
ls -lh "${OUT_IMG}.xz"
sha256sum "${OUT_IMG}.xz" | tee "$OUT/sha256sums.txt"
