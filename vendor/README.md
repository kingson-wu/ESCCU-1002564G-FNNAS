# vendor/image-url.txt 使用说明

把「设备已验证能启动」的那份固件直链粘贴到 vendor/image-url.txt（一行，http/https 开头），
push 后会自动触发 Build Vendor-Base Image 工作流。

支持的格式：.img / .img.gz / .img.xz / .zip（内含 .img）/ .tar.gz。
若是 .rar，请先自行解压成 .img 再上传到某个可直链下载的位置（或直接给 .img 的直链）。

固定用途：只替换内核（6.18.63-ophub）与本板设备树，分区/loader/u-boot 一律不动。
