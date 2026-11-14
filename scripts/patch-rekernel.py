#!/usr/bin/env python3
"""给 ophub/fnnas 的 rekernel 打一个小补丁：
当 fnnas-debs/.self_built 存在时，跳过「下载官方内核 debs」的步骤，
改用我们自己编译的 deb（避免官方内核与自编内核同时被装进镜像）。

用法：python3 patch-rekernel.py <path/to/rekernel>
"""
import sys

ANCHOR = '    echo -e "${STEPS} Downloading kernel deb packages..."\n'
GUARD = (
    '    if [[ -f "${current_path}/fnnas-debs/.self_built" ]]; then\n'
    '        echo -e "${INFO} Self-built debs detected, skip official download."\n'
    '        return\n'
    '    fi\n'
)


def main() -> int:
    path = sys.argv[1]
    src = open(path, encoding="utf-8").read()

    if "Self-built debs detected" in src:
        print("rekernel already patched")
        return 0

    if ANCHOR not in src:
        print("ERROR: anchor line not found in rekernel, upstream layout changed", file=sys.stderr)
        return 1

    open(path, "w", encoding="utf-8").write(src.replace(ANCHOR, ANCHOR + GUARD, 1))
    print("rekernel patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
