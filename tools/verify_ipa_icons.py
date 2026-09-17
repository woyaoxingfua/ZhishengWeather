# -*- coding: utf-8 -*-
"""解包 IPA，校验「备用 App 图标是否真的进了构建产物」。

为什么需要它
------------
actool 对**不存在的备用图标名静默忽略、零告警**。project.yml 里把
``ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`` 写成逗号串时，CI 全绿、
541 个测试全过、构建日志一条告警都没有，而运行期
``UIApplication.shared.supportsAlternateIcons`` 恒为 false，App 内换图标必然失败
（CI run 35217270251 实测：actool 收到的是**单个**名字
``--alternate-app-icon AppIcon-Jade,AppIcon-Rain``，该名字在 catalog 里不存在）。

开发机是 Windows、没有 Xcode，唯一能验证「图标到底能不能换」的办法就是
解包 IPA 看字节 —— 本脚本把这条链路固化成可复现、可当 CI 门禁用的一步。

三项检查（**全部**通过才 exit 0）
--------------------------------
1. ``Payload/*.app/Info.plist`` 的 ``CFBundleIcons.CFBundleAlternateIcons``
   同时包含每个期望的备用图标名（含 ``CFBundleIcons~ipad`` 的并集）；
2. ``Payload/*.app/Assets.car`` 里每个备用图标名的字节串出现次数 > 0
   （读 Info.plist 只能证明"声明了"，读 car 才能证明"图真的进了产物"）；
3. 主图标仍被声明（``CFBundleIcons.CFBundlePrimaryIcon``），防止顺手把
   主图标设置改坏。

退出码
------
0 全部满足；1 检查不通过（可用于 CI 门禁）；2 用法/IO/下载类错误。

用法
----
::

    # 本地解包好的 IPA（CI artifact 里的 ZhishengWeather-unsigned.ipa）
    python tools/verify_ipa_icons.py build/ZhishengWeather-unsigned.ipa

    # 也可直接喂 .zip（artifact 下载下来的就是 zip，里面含 .ipa）
    python tools/verify_ipa_icons.py /tmp/ZhishengWeather-unsigned-ipa.zip

    # 直接用 GitHub Actions 的 artifact id 下载并校验（走代理时给 --proxy）
    python tools/verify_ipa_icons.py --artifact-id 10494719935 \\
        --token "$GITHUB_TOKEN" --proxy http://127.0.0.1:7897
"""
import argparse
import os
import plistlib
import shutil
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

# 期望出现在产物里的备用图标名（与 Core/Models/AppIconChoice.swift 的
# alternateIconName 同源；此处**硬编码**，让脚本独立于被测代码）。
DEFAULT_EXPECT = ["AppIcon-Jade", "AppIcon-Rain"]

REPO = "woyaoxingfua/ZhishengWeather"
API = "https://api.github.com"

EXIT_OK = 0
EXIT_FAIL = 1
EXIT_ERROR = 2


class _StripAuthOnHostChange(urllib.request.HTTPRedirectHandler):
    """跨主机跳转时摘掉 Authorization。

    artifact 下载是 302 跳到 objects.githubusercontent.com 的签名 URL；把
    GitHub 的 Bearer 头带过去会被 S3 判成"只允许一种鉴权方式"而 400。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is None:
            return None
        same_host = urllib.parse.urlsplit(newurl).netloc == urllib.parse.urlsplit(req.full_url).netloc
        if not same_host:
            new.headers.pop("Authorization", None)
        return new


def build_opener(proxy):
    handlers = [_StripAuthOnHostChange()]
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers)


def download_artifact(artifact_id, token, proxy, dst_dir):
    """下载并解压某个 artifact，返回解压目录。

    带 3 次重试：本地走 HTTP 代理时握手偶发 SSLEOFError（实测过一次），
    这类瞬时网络抖动不该让一次验证直接判错。
    """
    if not token:
        raise RuntimeError("从 artifact 下载需要 --token（或环境变量 GITHUB_TOKEN）")
    api = "%s/repos/%s/actions/artifacts/%s/zip" % (API, REPO, artifact_id)
    req = urllib.request.Request(api, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "verify-ipa-icons",
    })

    payload = None
    last_error = None
    for attempt in range(3):
        try:
            payload = build_opener(proxy).open(req, timeout=300).read()
            break
        except urllib.error.HTTPError as exc:
            raise RuntimeError("下载 artifact %s 失败：HTTP %s（%s）"
                               % (artifact_id, exc.code, exc.reason))
        except Exception as exc:  # noqa: BLE001 —— 网络层异常一律收敛为运行期错误
            last_error = exc
            print("第 %d 次下载失败（%r），重试…" % (attempt + 1, exc), flush=True)
    if payload is None:
        raise RuntimeError("下载 artifact %s 失败（已重试 3 次）：%r" % (artifact_id, last_error))

    zip_path = os.path.join(dst_dir, "artifact-%s.zip" % artifact_id)
    with open(zip_path, "wb") as fh:
        fh.write(payload)
    print("已下载 artifact %s（%d 字节）→ %s" % (artifact_id, len(payload), zip_path))

    out_dir = os.path.join(dst_dir, "artifact-%s" % artifact_id)
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(out_dir)
    return out_dir


def find_app_dir(root, _depth=0):
    """在解包目录里找 Payload/*.app。

    CI 的 artifact 包是「zip 套 ipa」两层（artifact zip → *.ipa → Payload/*.app），
    故先直接扫，扫不到就把嵌套的 .ipa / .zip 再解一层（最多两层）。
    """
    for dirpath, dirnames, _ in os.walk(root):
        for name in list(dirnames):
            if name.endswith(".app"):
                candidate = os.path.join(dirpath, name)
                if os.path.isfile(os.path.join(candidate, "Info.plist")):
                    return candidate
    if _depth >= 2:
        return None

    # 先收集完再解包：避免在 os.walk 迭代过程中改动目录树。
    nested_archives = []
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.lower().endswith((".ipa", ".zip")):
                nested_archives.append(os.path.join(dirpath, name))

    for archive in nested_archives:
        nested = archive + ".extracted"
        os.makedirs(nested, exist_ok=True)
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(nested)
        print("已解包嵌套归档：%s" % os.path.basename(archive))
        hit = find_app_dir(nested, _depth + 1)
        if hit:
            return hit
    return None


def collect_alternate_icons(plist):
    """从 Info.plist 汇总额备用图标名（iPhone + iPad 两个族取并集）。

    只查 ``CFBundleIcons`` 会漏判 iPad（``CFBundleIcons~ipad`` 是独立的一份）。
    """
    names = set()
    per_key = {}
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icons = plist.get(key)
        if not isinstance(icons, dict):
            continue
        alternates = icons.get("CFBundleAlternateIcons")
        keys = sorted(alternates.keys()) if isinstance(alternates, dict) else []
        per_key[key] = keys
        names.update(keys)
    return names, per_key


def count_bytes(path, needle):
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        return fh.read().count(needle.encode("utf-8"))


def verify(app_dir, expect):
    """返回 (失败计数, 检查明细行列表)。"""
    failures = 0
    lines = []

    def line(text):
        lines.append(text)

    line("被测 App bundle：%s" % app_dir)

    info_path = os.path.join(app_dir, "Info.plist")
    with open(info_path, "rb") as fh:
        plist = plistlib.load(fh)

    line("")
    line("── 检查 1：Info.plist 的 CFBundleIcons ──")
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icon_dict = plist.get(key)
        if icon_dict is None:
            line("  %s：<不存在>" % key)
        else:
            line("  %s = %s" % (key, _fmt(icon_dict)))
    declared, per_key = collect_alternate_icons(plist)
    line("  CFBundleAlternateIcons 汇总 = %s" % (sorted(declared) if declared else "（空）"))
    if not declared:
        failures += 1
        line("  ✗ 没有任何 CFBundleAlternateIcons → 运行期 supportsAlternateIcons == false，"
             "App 内换图标必然失败")
    for name in expect:
        if name in declared:
            line("  ✓ 声明了 %s" % name)
        else:
            failures += 1
            line("  ✗ 缺少 %s（按设备族：%s）" % (name, per_key))

    line("")
    line("── 检查 2：Assets.car 里备用图标的字节串 ──")
    car_path = os.path.join(app_dir, "Assets.car")
    if not os.path.isfile(car_path):
        failures += 1
        line("  ✗ 找不到 Assets.car（%s）" % car_path)
    else:
        line("  Assets.car 大小 = %d 字节" % os.path.getsize(car_path))
        for name in expect:
            hits = count_bytes(car_path, name)
            if hits and hits > 0:
                line("  ✓ 字节串 %r 出现 %d 次（图真的进了产物）" % (name, hits))
            else:
                failures += 1
                line("  ✗ 字节串 %r 出现 0 次（备用图标的图没进产物）" % name)
        line("  参考：字节串 'AppIcon' 出现 %d 次" % count_bytes(car_path, "AppIcon"))
        line("  注：本检查假定 actool 把图标集名以 ASCII 原样写进 Assets.car；"
             "反例已在坏构建上验证（0 次），正例待一次绿色构建确认。")

    line("")
    line("── 检查 3：主图标仍在 ──")
    primary_ok = False
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icon_dict = plist.get(key)
        if isinstance(icon_dict, dict) and isinstance(icon_dict.get("CFBundlePrimaryIcon"), dict):
            primary = icon_dict["CFBundlePrimaryIcon"]
            line("  %s.CFBundlePrimaryIcon = %s" % (key, _fmt(primary)))
            if primary.get("CFBundleIconName"):
                primary_ok = True
            if primary.get("CFBundleIconFiles"):
                primary_ok = True
    if primary_ok:
        line("  ✓ 主图标已声明")
    else:
        failures += 1
        line("  ✗ 没有找到 CFBundlePrimaryIcon（主图标设置被改坏？）")

    return failures, lines


def _fmt(value, limit=400):
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "...(截断)"


def resolve_ipa_root(source, work_dir):
    """把输入（文件路径）统一变成"可搜索的根目录"。"""
    lower = source.lower()
    if lower.endswith(".ipa"):
        out_dir = os.path.join(work_dir, "ipa")
        os.makedirs(out_dir, exist_ok=True)
        with zipfile.ZipFile(source) as zf:
            zf.extractall(out_dir)
        print("已解包 IPA：%s" % source)
        return out_dir
    if lower.endswith(".zip"):
        out_dir = os.path.join(work_dir, "zip")
        os.makedirs(out_dir, exist_ok=True)
        with zipfile.ZipFile(source) as zf:
            zf.extractall(out_dir)
        print("已解包 zip：%s" % source)
        return out_dir
    raise RuntimeError("不认识的输入（期望 .ipa / .zip）：%s" % source)


def main():
    parser = argparse.ArgumentParser(
        description="解包 IPA 校验备用 App 图标是否真的进了构建产物",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", nargs="?",
                        help="IPA 或 zip（artifact 下载包）路径")
    parser.add_argument("--artifact-id", help="改为从 GitHub Actions artifact id 下载")
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN"),
                        help="GitHub token（下载 artifact 用；默认取 $GITHUB_TOKEN）")
    parser.add_argument("--proxy", default=os.environ.get("HTTPS_PROXY"),
                        help="代理，例如 http://127.0.0.1:7897（默认取 $HTTPS_PROXY）")
    parser.add_argument("--expect", action="append", default=None,
                        help="期望的备用图标名，可重复；默认 %s" % ",".join(DEFAULT_EXPECT))
    args = parser.parse_args()

    if not args.path and not args.artifact_id:
        parser.error("必须给一个 IPA/zip 路径，或 --artifact-id")

    expect = args.expect or DEFAULT_EXPECT

    work_dir = tempfile.mkdtemp(prefix="verify-ipa-icons-")
    try:
        if args.artifact_id:
            root = download_artifact(args.artifact_id, args.token, args.proxy, work_dir)
        else:
            if not os.path.isfile(args.path):
                print("路径不存在：%s" % args.path, file=sys.stderr)
                return EXIT_ERROR
            root = resolve_ipa_root(args.path, work_dir)

        app_dir = find_app_dir(root)
        if app_dir is None:
            print("在 %s 下找不到 Payload/*.app（含 Info.plist）" % root, file=sys.stderr)
            return EXIT_ERROR

        failures, lines = verify(app_dir, expect)
        print("\n".join(lines))
        print("")
        if failures:
            print("结论：✗ 有 %d 项不满足 —— 备用图标没有真正进产物，App 内换图标会失败" % failures)
            return EXIT_FAIL
        print("结论：✓ 两个备用图标都已进产物（%s）" % ", ".join(expect))
        return EXIT_OK
    except RuntimeError as exc:
        print("错误：%s" % exc, file=sys.stderr)
        return EXIT_ERROR
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
