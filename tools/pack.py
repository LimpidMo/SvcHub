#!/usr/bin/env python3
# SvcHub 模块打包：只收录刷机必需文件，版本命名入 dist/，不覆盖同名包
# 用法：
#   python tools/pack.py                # 校验清单并打正式包 dist/SvcHub_v<ver>.zip
#   python tools/pack.py --tag X        # 打测试包 dist/SvcHub_v<ver>_X.zip
#   python tools/pack.py --check        # 只校验清单与 exec 位，不打包
# 输出覆盖写 dist/SHA256.txt（单行：哈希  包名）；同名包自动递增 _1/_2
import hashlib
import os
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 刷机必需文件（14 个）：脚本 + 配置 + 前端 + CGI + META-INF
REQUIRED_FILES = [
    "module.prop",
    "customize.sh",
    "service.sh",
    "supervisor.sh",
    "action.sh",
    "uninstall.sh",
    "lib.sh",
    "httpd.sh",
    "config/web.conf",
    "webroot/index.html",
    "webroot/cgi-bin/api.cgi",
    "system/etc/resolv.conf",
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
]

# 设备上必须可执行：刷入后 zip 内权限位生效（busybox 按可执行判定 CGI）
EXEC_BITS = (".sh", ".cgi")


def is_exec_file(path):
    return path.endswith(EXEC_BITS) or path.endswith("update-binary")


def module_version():
    with open(os.path.join(REPO, "module.prop"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("version="):
                return line.split("=", 1)[1].strip()
    sys.exit("module.prop 缺少 version 字段")


def check():
    """校验清单完整性与 exec 位，返回缺失/权限问题列表"""
    bad = []
    for rel in REQUIRED_FILES:
        p = os.path.join(REPO, rel)
        if not os.path.isfile(p):
            bad.append("缺失: " + rel)
            continue
        if is_exec_file(rel) and not os.access(p, os.X_OK):
            bad.append("无可执行位: " + rel)
    return bad


def pack(tag=None):
    ver = module_version()
    name = "SvcHub_v%s%s.zip" % (ver, ("_" + tag) if tag else "")
    dist = os.path.join(REPO, "dist")
    os.makedirs(dist, exist_ok=True)
    out, n = os.path.join(dist, name), 1
    while os.path.exists(out):
        out = os.path.join(dist, "SvcHub_v%s%s_%d.zip" % (ver, ("_" + tag) if tag else "", n))
        n += 1
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in REQUIRED_FILES:
            p = os.path.join(REPO, rel)
            zi = zipfile.ZipInfo.from_file(p, rel)
            # Windows 无 POSIX 权限位，手动写权限：脚本 755 / 资源 644
            zi.external_attr = (0o755 if is_exec_file(rel) else 0o644) << 16
            with open(p, "rb") as f:
                z.writestr(zi, f.read())
    with open(out, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    with open(os.path.join(dist, "SHA256.txt"), "w", encoding="utf-8") as f:
        f.write("%s  %s\n" % (digest, os.path.basename(out)))
    return out, digest


def main():
    args = sys.argv[1:]
    only_check = "--check" in args
    tag = None
    if "--tag" in args:
        tag = args[args.index("--tag") + 1]
    bad = check()
    if bad:
        print("校验失败：")
        for b in bad:
            print("  " + b)
        sys.exit(1)
    print("校验通过：%d 个文件齐全，脚本 exec 位正常" % len(REQUIRED_FILES))
    if only_check and not tag:
        return
    out, digest = pack(tag)
    print("已打包：%s" % os.path.relpath(out, REPO))
    print("SHA256：%s" % digest)
    print("已写入：dist/SHA256.txt")


if __name__ == "__main__":
    main()
