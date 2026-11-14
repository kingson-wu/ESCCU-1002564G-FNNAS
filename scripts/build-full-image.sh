#!/usr/bin/env bash
# ==========================================================================
# 把自编内核包(x.x.xx-rockchip.tar.gz 里的 boot/dtb/modules/headers) 烤进
# 一份现成的 Rockchip 整机镜像（官方 FnNAS rockchip 镜像，或设备已验证能
# 启动的 vendor 镜像），产出可直接用 「loader + .img」 刷写的镜像。
#
# 用法：
#   sudo ./build-full-image.sh <镜像.img> <内核包解包目录> <输出目录> [输出名前缀]
#
# 踩过的坑（都在这里修掉了）：
#   * 底镜像里 vmlinuz / uInitrd 往往是**软链接**（vmlinuz -> vmlinuz-6.18.18-trim），
#     只放新内核文件不改链接 → 启动的还是旧内核。必须重指软链接，
#     并把 extlinux.conf 的 linux / initrd / fdt 三行一起改。
#   * 内核版本号必须从**包文件名**推断（boot-rockchip-6.18.63-ophub.tar.gz），
#     不要 ls /usr/lib/modules 去猜（底镜像里可能有 6.1.0-xxx 之类的残留目录）。
#   * 有些底镜像（如飞牛官方 roc-rk3568-pc）根本没有 extlinux.conf，dtb 由
#     u-boot 按固定文件名加载，此时必须把同名 dtb 直接覆盖成本板 dtb。
# ==========================================================================
set -euo pipefail

IMG="${1:?用法: build-full-image.sh <img> <pkgdir> <outdir> [name]}"
PKG="${2:?缺少内核包解包目录}"
OUT="${3:?缺少输出目录}"
NAME="${4:-FnNAS}"
DTB_NAME="rk3568-firefly-aioj.dtb"

[[ $EUID -eq 0 ]] || { echo "需要 root"; exit 1; }
for t in losetup mount xz tar; do command -v "$t" >/dev/null || { echo "缺少 $t"; exit 1; }; done

mkdir -p "$OUT"
LOOP=""; R=""; B=""
cleanup() {
    set +e
    [[ -n "$B" ]] && mountpoint -q "$B" && umount "$B"
    [[ -n "$R" ]] && mountpoint -q "$R" && umount "$R"
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# ---------- 0) 内核包信息 ----------
boottar="$(ls "$PKG"/boot-rockchip-*.tar.gz | head -1)"
dtbtar="$(ls "$PKG"/dtb-rockchip-*.tar.gz | head -1)"
modtar="$(ls "$PKG"/modules-rockchip-*.tar.gz | head -1)"
hdrtar="$(ls "$PKG"/header-rockchip-*.tar.gz | head -1)"
SUFFIX="$(basename "$boottar" | sed -E 's/^boot-rockchip-(.*)\.tar\.gz$/\1/')"
VMLINUZ="vmlinuz-${SUFFIX}"
UINITRD="uInitrd-${SUFFIX}"
echo "==> 内核 suffix=${SUFFIX}  ($VMLINUZ)"
[[ -n "$SUFFIX" ]] || { echo "!! 无法从包名推断内核版本"; exit 1; }

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
            ROOT_PART="$p"; echo "    rootfs: $p"
        elif [[ -d /mnt/probe/extlinux || -f /mnt/probe/armbianEnv.txt || -d /mnt/probe/dtb ]]; then
            BOOT_PART="$p"; echo "    boot:   $p"
        fi
        umount /mnt/probe
    fi
done
[[ -n "$ROOT_PART" ]] || { echo "!! 找不到 rootfs 分区"; exit 1; }

R=/mnt/root
mount -o rw "$ROOT_PART" "$R"
if [[ -n "$BOOT_PART" ]]; then
    B=/mnt/boot; mount -o rw "$BOOT_PART" "$B"
else
    B="$R/boot"
fi
echo "    rootfs -> $R, boot -> $B"

# ---------- 2) 写入内核（boot） ----------
echo "==> 写入 /boot"
echo "--- 替换前 ---"
ls -l "$B" | grep -E "vmlinuz|uInitrd|initrd" || true
tar -xzf "$boottar" -C "$B"
echo "--- 替换后 ---"
ls -l "$B" | grep -E "vmlinuz|uInitrd|initrd" || true

# 底镜像若用软链接（vmlinuz/uInitrd -> 旧版本），重指到自编内核
for n in vmlinuz uInitrd initrd.img; do
    if [[ -L "$B/$n" ]]; then
        case "$n" in
            vmlinuz)    ln -sfn "$VMLINUZ" "$B/$n" ;;
            uInitrd)    ln -sfn "$UINITRD" "$B/$n" ;;
            initrd.img) ln -sfn "initrd.img-${SUFFIX}" "$B/$n" ;;
        esac
        echo "    重指软链接: $n -> $(readlink "$B/$n")"
    fi
done

# ---------- 3) dtb ----------
echo "==> 写入 /boot/dtb/rockchip/"
mkdir -p "$B/dtb/rockchip"
tar -xzf "$dtbtar" -C "$B/dtb/rockchip"
[[ -f "$B/dtb/rockchip/$DTB_NAME" ]] || { echo "!! 本板 dtb 缺失"; exit 1; }
echo "    dtb 总数: $(find "$B/dtb/rockchip" -name '*.dtb' | wc -l)"
echo "--- boot 目录清单（排查引导方式用） ---"
ls -l "$B" | head -40
echo "--- 底镜像里 Firefly RK3568 系列 dtb ---"
find "$B/dtb" -maxdepth 2 -name 'rk3568-firefly*' -o -maxdepth 2 -name 'rk3568-roc*' 2>/dev/null | head -20

# ---------- 4) 模块 / headers ----------
echo "==> 写入 /usr/lib/modules/${SUFFIX}"
mkdir -p "$R/usr/lib/modules"
tar -xzf "$modtar" -C "$R/usr/lib/modules"
MDIR="$R/usr/lib/modules/${SUFFIX}"
[[ -d "$MDIR/kernel" ]] || { echo "!! 模块目录不对: $MDIR"; ls "$R/usr/lib/modules"; exit 1; }
[[ -f "$MDIR/modules.dep" ]] || echo "    warn: modules.dep 缺失"

echo "==> 写入 /usr/src headers"
mkdir -p "$R/usr/src"
tar -xzf "$hdrtar" -C "$R/usr/src" || echo "    warn: headers 解包失败（不影响启动）"

# ---------- 5) 引导配置：linux / initrd / fdt 三行齐改 ----------
changed=0
for base in "$B" "$R/boot"; do
    [[ -d "$base" ]] || continue
    if [[ -f "$base/extlinux/extlinux.conf" ]]; then
        cp -f "$base/extlinux/extlinux.conf" "$base/extlinux/extlinux.conf.bak" || true
        sed -i -E "s|^(\s*)linux\s.*|\1linux /${VMLINUZ}|" "$base/extlinux/extlinux.conf"
        sed -i -E "s|^(\s*)initrd\s.*|\1initrd /${UINITRD}|" "$base/extlinux/extlinux.conf"
        sed -i -E "s|^(\s*)fdt\s.*|\1fdt /dtb/rockchip/${DTB_NAME}|" "$base/extlinux/extlinux.conf"
        grep -q "${DTB_NAME}" "$base/extlinux/extlinux.conf" || \
            printf '\nfdt /dtb/rockchip/%s\n' "$DTB_NAME" >> "$base/extlinux/extlinux.conf"
        echo "--- extlinux.conf 关键行 ---"
        grep -nE 'label|linux |initrd |fdt |append' "$base/extlinux/extlinux.conf" | head -8 || true
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

# ---------- 5b) 无引导配置时的兜底：覆盖 u-boot 按名字加载的 Firefly RK3568 dtb ----------
if [[ $changed -eq 0 ]]; then
    echo "==> 底镜像无引导配置，按 u-boot 固定文件名覆盖 dtb"
    cnt=0
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" == "$DTB_NAME" ]] && continue
        cp -f "$B/dtb/rockchip/$DTB_NAME" "$f"
        echo "    覆盖: ${f#"$B"/} ($(basename "$f"))"
        cnt=$((cnt + 1))
    done < <(find "$B/dtb/rockchip" -maxdepth 1 \( -name 'rk3568-firefly*.dtb' -o -name 'rk3568-roc*.dtb' -o -name 'rk3568-station*.dtb' \) 2>/dev/null)
    echo "    共覆盖 ${cnt} 个 dtb"
    [[ $cnt -gt 0 ]] || echo "!! 没有可覆盖的 Firefly RK3568 dtb 文件名，需要人工确认 u-boot 的 fdtfile"
fi

sync

# ---------- 6) 报告 ----------
{
    echo "kernel suffix: ${SUFFIX}"
    echo "vmlinuz link: vmlinuz -> $(readlink "$B/vmlinuz" 2>/dev/null || echo '(not a symlink)')"
    echo "uInitrd link: uInitrd -> $(readlink "$B/uInitrd" 2>/dev/null || echo '(not a symlink)')"
    echo "dtb: ${DTB_NAME} present at /boot/dtb/rockchip"
    echo "fallback dtb override: ${cnt:-0} file(s)"
    echo "modules: /usr/lib/modules/${SUFFIX} ($(ls "$MDIR/kernel" | wc -l) groups)"
    echo "extlinux: $(grep -m1 'fdt' "$B/extlinux/extlinux.conf" 2>/dev/null || echo n/a)"
    echo "linux cfg: $(grep -m1 'linux ' "$B/extlinux/extlinux.conf" 2>/dev/null || echo n/a)"
} | tee "$OUT/report.txt"

cleanup
trap - EXIT

# ---------- 7) 压缩 ----------
OUT_IMG="$OUT/${NAME}-${SUFFIX}.img"
mv "$IMG" "$OUT_IMG"
echo "==> 压缩（xz -9 -T2）"
xz -9 -T2 -c "$OUT_IMG" > "${OUT_IMG}.xz"
rm -f "$OUT_IMG"
ls -lh "${OUT_IMG}.xz"
sha256sum "${OUT_IMG}.xz" | tee "$OUT/sha256sums.txt"
