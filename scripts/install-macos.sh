#!/bin/bash
# ============================================================
#  dsh-purge macOS installer (one file)
#
#    bash scripts/install-macos.sh
#    bash scripts/install-macos.sh web
#    bash scripts/install-macos.sh desktop
#    bash scripts/install-macos.sh both
#    bash scripts/install-macos.sh web "$HOME/.dsh"
#    bash scripts/install-macos.sh --dry-run
#    bash scripts/install-macos.sh --self-test
#
#  Repo: https://github.com/niuniuqiu/dsh-purge.git
#  Does not restart the host and does not click Apply.
#  Double-click: copy or rename this file to install-macos.command
# ============================================================
set -eu

pause_at_end=0
base=$(basename "$0")
case "$base" in
  *.command) pause_at_end=1 ;;
esac

pick_python() {
  if /opt/homebrew/bin/python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    printf '%s\n' /opt/homebrew/bin/python3
    return 0
  fi
  if /usr/local/bin/python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    printf '%s\n' /usr/local/bin/python3
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

if ! py=$(pick_python); then
  echo "找不到 python3。这个安装脚本需要 Python 3.8 或更新版本。"
  echo "可以安装 Xcode 命令行工具，或执行: brew install python"
  exit 1
fi

if ! grep -q '^###DSH_PURGE_PY###$' "$0"; then
  echo "marker missing"
  exit 1
fi

tmp="$(mktemp -t dsh-purge-install)"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT
awk '
  /^###DSH_PURGE_PY###$/ { state = 1; next }
  /^END_DSH_PURGE_PY$/ { if (state == 1) exit }
  state == 1 { print }
' "$0" > "$tmp"
if [ ! -s "$tmp" ]; then
  echo "Failed to prepare the installer script."
  exit 1
fi

set +e
PYTHONIOENCODING=utf-8 PYTHONUNBUFFERED=1 "$py" "$tmp" "$@"
ec=$?
set -e

if [ "$pause_at_end" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
  printf '\n按回车关闭...\n'
  read -r _ || true
fi
exit "$ec"

: <<'END_DSH_PURGE_PY'
###DSH_PURGE_PY###
# -*- coding: utf-8 -*-
"""macOS installer body. Invoked by the shell wrapper above."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

GIT_REPO = "https://github.com/niuniuqiu/dsh-purge.git"
DEP_VALUE = "file:../../plugins/dsh-purge"
BACKUPS = []
DSH_SOURCE = None


class InstallError(Exception):
    pass


def say(msg=""):
    print(msg, flush=True)


def ps_str(value):
    if isinstance(value, bool):
        return "True" if value else "False"
    if value is None:
        return ""
    return str(value)


def load_json(text, err):
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise InstallError(err) from exc


def read_text_file(path):
    with open(path, "rb") as handle:
        raw = handle.read()
    if len(raw) >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
        raise InstallError("文件是 UTF-16，未修改: " + path)
    if len(raw) >= 2 and raw[0] == 0xFE and raw[1] == 0xFF:
        raise InstallError("文件是 UTF-16，未修改: " + path)
    if raw.startswith(b"\xef\xbb\xbf"):
        return {"text": raw[3:].decode("utf-8"), "enc": "utf-8", "bom": True}
    try:
        return {"text": raw.decode("utf-8"), "enc": "utf-8", "bom": False}
    except UnicodeDecodeError:
        pass
    try:
        return {"text": raw.decode("gb18030"), "enc": "gb18030", "bom": False}
    except UnicodeDecodeError:
        return {"text": raw.decode("latin-1"), "enc": "latin-1", "bom": False}


def write_text_file(path, text, info):
    enc = info["enc"]
    if enc == "utf-8":
        body = text.encode("utf-8")
        data = b"\xef\xbb\xbf" + body if info.get("bom") else body
    elif enc == "gb18030":
        data = text.encode("gb18030")
    else:
        data = text.encode("latin-1")
    with open(path, "wb") as handle:
        handle.write(data)


def read_json_string(text, quote_idx):
    if text[quote_idx] != '"':
        raise InstallError("package.json 字符串起点不对，文件未修改")
    i = quote_idx + 1
    esc = False
    while i < len(text):
        ch = text[i]
        if esc:
            esc = False
            i += 1
            continue
        if ch == "\\":
            esc = True
            i += 1
            continue
        if ch == '"':
            literal = text[quote_idx:i + 1]
            try:
                value = json.loads(literal)
            except json.JSONDecodeError as exc:
                raise InstallError("package.json 字符串无法解析，文件未修改") from exc
            return i, value
        i += 1
    raise InstallError("package.json 字符串没有结束引号，文件未修改")


def skip_ws(text, index, limit):
    i = index
    while i < limit and text[i].isspace():
        i += 1
    return i


def get_container_end(text, open_idx):
    open_ch = text[open_idx]
    if open_ch == "{":
        close_ch = "}"
    elif open_ch == "[":
        close_ch = "]"
    else:
        raise InstallError("package.json 括号起点不对，文件未修改")
    depth = 0
    i = open_idx
    while i < len(text):
        ch = text[i]
        if ch == '"':
            end, _value = read_json_string(text, i)
            i = end + 1
            continue
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise InstallError("package.json 括号不配对，文件未修改")


def find_root_open(text):
    i = skip_ws(text, 0, len(text))
    if i >= len(text) or text[i] != "{":
        raise InstallError("package.json 不是以 { 开头，文件未修改")
    return i


def find_property_value_start(text, obj_open, key):
    if text[obj_open] != "{":
        raise InstallError("内部错误: 不是对象")
    obj_end = get_container_end(text, obj_open)
    i = obj_open + 1
    depth = 1
    while i < obj_end:
        ch = text[i]
        if ch == '"':
            end, value = read_json_string(text, i)
            i = end + 1
            if depth == 1:
                j = skip_ws(text, i, obj_end)
                if j < obj_end and text[j] == ":":
                    if value == key:
                        j += 1
                        return skip_ws(text, j, obj_end)
            continue
        if ch in "{[":
            depth += 1
            i += 1
            continue
        if ch in "}]":
            depth -= 1
            i += 1
            continue
        i += 1
    return -1


def insert_before_container_end(text, open_idx, token):
    close_idx = get_container_end(text, open_idx)
    nl = "\r\n" if "\r\n" in text else "\n"
    inner_empty = True
    for k in range(open_idx + 1, close_idx):
        if not text[k].isspace():
            inner_empty = False
            break
    line_start = text.rfind("\n", 0, close_idx + 1)
    if line_start < 0:
        line_start = 0
    else:
        line_start += 1
    base_indent = ""
    for k in range(line_start, close_idx):
        ch = text[k]
        if ch in " \t":
            base_indent += ch
        else:
            break
    if inner_empty:
        item_indent = base_indent + "  "
        ins = nl + item_indent + token + nl + base_indent
        return text[:open_idx + 1] + ins + text[close_idx:]
    i = close_idx - 1
    while i > open_idx and text[i].isspace():
        i -= 1
    item_indent = ""
    last_nl = text.rfind("\n", 0, i + 1)
    if last_nl < 0:
        item_indent = "  "
    else:
        for k in range(last_nl + 1, i + 1):
            ch = text[k]
            if ch in " \t":
                item_indent += ch
            else:
                break
        if not item_indent:
            item_indent = base_indent + "  "
    needs_comma = text[i] != "," and text[i] != text[open_idx]
    comma = "," if needs_comma else ""
    ins = comma + nl + item_indent + token
    return text[:i + 1] + ins + text[i + 1:]


def get_dep_map(obj):
    if not isinstance(obj, dict):
        return {}
    return dict(obj)


def get_bundle_list(obj):
    dsh = obj.get("dsh") if isinstance(obj, dict) else None
    profile = dsh.get("profile") if isinstance(dsh, dict) else None
    if not isinstance(profile, dict):
        raise InstallError("缺少 dsh.profile，已放弃写入")
    raw = profile.get("bundles")
    items = []
    if isinstance(raw, list):
        for item in raw:
            if item is not None:
                items.append(ps_str(item))
    elif raw is not None:
        items.append(ps_str(raw))
    return items


def get_reload(obj):
    dsh = obj.get("dsh") if isinstance(obj, dict) else None
    profile = dsh.get("profile") if isinstance(dsh, dict) else None
    if not isinstance(profile, dict) or "patchReload" not in profile:
        return None
    return ps_str(profile.get("patchReload"))


def assert_same_prop(before, after, name):
    b_missing = name not in before
    a_missing = name not in after
    if b_missing != a_missing:
        raise InstallError(name + " 被改动，已放弃写入")
    if not b_missing and ps_str(before[name]) != ps_str(after[name]):
        raise InstallError(name + " 被改动，已放弃写入")


def assert_invariants(before, after):
    for name in ("name", "version", "private", "description"):
        assert_same_prop(before, after, name)
    if get_reload(before) != get_reload(after):
        raise InstallError("patchReload 被改动，已放弃写入")

    before_count = len(before)
    after_count = len(after)
    had_deps = "dependencies" in before
    if had_deps:
        if after_count != before_count:
            raise InstallError("顶层字段数量变了，已放弃写入")
    elif after_count != before_count + 1:
        raise InstallError("顶层字段数量不对，已放弃写入")

    before_deps = get_dep_map(before.get("dependencies"))
    after_deps = get_dep_map(after.get("dependencies"))
    for key, value in before_deps.items():
        if key == "dsh-purge":
            continue
        if key not in after_deps:
            raise InstallError("依赖 " + key + " 丢失，已放弃写入")
        if ps_str(value) != ps_str(after_deps[key]):
            raise InstallError("依赖 " + key + " 被改动，已放弃写入")
    for key in after_deps:
        if key == "dsh-purge":
            continue
        if key not in before_deps:
            raise InstallError("多出依赖 " + key + "，已放弃写入")
    if "dsh-purge" not in after_deps:
        raise InstallError("没有写入 dependencies.dsh-purge，已放弃写入")
    if ps_str(after_deps["dsh-purge"]) != DEP_VALUE:
        raise InstallError("dsh-purge 不是 file:../../plugins/dsh-purge，已放弃写入")

    before_bundles = get_bundle_list(before)
    after_bundles = get_bundle_list(after)
    had = any(item == "dsh-purge" for item in before_bundles)
    if had:
        if len(before_bundles) != len(after_bundles):
            raise InstallError("bundles 数量变了，已放弃写入")
        for idx in range(len(before_bundles)):
            if before_bundles[idx] != after_bundles[idx]:
                raise InstallError("bundles 被改动，已放弃写入")
    else:
        if len(after_bundles) != len(before_bundles) + 1:
            raise InstallError("bundles 追加结果不对，已放弃写入")
        for idx in range(len(before_bundles)):
            if before_bundles[idx] != after_bundles[idx]:
                raise InstallError("原有 bundle 被改动，已放弃写入")
        if not after_bundles or after_bundles[-1] != "dsh-purge":
            raise InstallError("dsh-purge 没有加在 bundles 末尾，已放弃写入")


def update_profile_text(text):
    before = load_json(text, "package.json 无法解析，文件未修改")
    if DEP_VALUE != "file:../../plugins/dsh-purge":
        raise InstallError("内部错误: 依赖路径不对")
    root = find_root_open(text)
    literal = json.dumps(DEP_VALUE, ensure_ascii=False)

    dep_idx = find_property_value_start(text, root, "dependencies")
    if dep_idx < 0:
        text = insert_before_container_end(
            text, root, '"dependencies": { "dsh-purge": ' + literal + " }"
        )
    else:
        if text[dep_idx] != "{":
            raise InstallError("dependencies 不是对象，文件未修改")
        exist = find_property_value_start(text, dep_idx, "dsh-purge")
        if exist < 0:
            text = insert_before_container_end(text, dep_idx, '"dsh-purge": ' + literal)
        else:
            if text[exist] != '"':
                raise InstallError("dependencies.dsh-purge 不是字符串，文件未修改")
            end, _value = read_json_string(text, exist)
            cur_lit = text[exist:end + 1]
            try:
                cur_val = json.loads(cur_lit)
            except json.JSONDecodeError as exc:
                raise InstallError("dependencies.dsh-purge 无法解析，文件未修改") from exc
            if ps_str(cur_val) != DEP_VALUE:
                text = text[:exist] + literal + text[end + 1:]

    root = find_root_open(text)
    dsh_idx = find_property_value_start(text, root, "dsh")
    if dsh_idx < 0 or text[dsh_idx] != "{":
        raise InstallError("缺少 dsh 对象，文件未修改")
    prof_idx = find_property_value_start(text, dsh_idx, "profile")
    if prof_idx < 0 or text[prof_idx] != "{":
        raise InstallError("缺少 dsh.profile，文件未修改")
    bun_idx = find_property_value_start(text, prof_idx, "bundles")
    if bun_idx < 0 or text[bun_idx] != "[":
        raise InstallError("缺少 dsh.profile.bundles 数组，文件未修改")

    mid = load_json(text, "修改 dependencies 后 JSON 无法解析，已放弃写入")
    raw_bundles = None
    dsh = mid.get("dsh") if isinstance(mid, dict) else None
    profile = dsh.get("profile") if isinstance(dsh, dict) else None
    if isinstance(profile, dict):
        raw_bundles = profile.get("bundles")
    has = False
    if isinstance(raw_bundles, list):
        has = any(ps_str(item) == "dsh-purge" for item in raw_bundles)
    elif raw_bundles is not None and ps_str(raw_bundles) == "dsh-purge":
        has = True
    if not has:
        text = insert_before_container_end(text, bun_idx, '"dsh-purge"')

    after = load_json(text, "修改后的 JSON 无法解析，已放弃写入")
    assert_invariants(before, after)
    return text


def update_profile_file(path, dry_run):
    info = read_text_file(path)
    old = info["text"]
    new = update_profile_text(old)
    if new == old:
        say("      已有 dsh-purge，package.json 不改")
        return
    if dry_run:
        say("      [dry-run] 将追加 dependencies 与 bundles 里缺少的 dsh-purge，不写文件")
        return
    stamp = time.strftime("%Y%m%d-%H%M%S")
    bak = path + ".bak-dsh-purge-" + stamp
    tmp = path + ".tmp-dsh-purge"
    try:
        write_text_file(tmp, new, info)
        back = read_text_file(tmp)["text"]
        if back != new:
            raise InstallError("临时文件读回不一致")
        shutil.copy2(path, bak)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
        raise
    BACKUPS.append(bak)
    say("      已写入，并备份到")
    say("      " + bak)


def clean_path(path):
    path = str(path).strip().strip('"').strip("'").rstrip("/\\")
    if not path:
        return ""
    return os.path.abspath(os.path.expanduser(path))


def add_unique_dir(items, directory):
    if not directory:
        return
    directory = str(directory).strip().rstrip("/")
    if not directory or directory == "/":
        return
    leaf = os.path.basename(directory)
    if leaf in ("Users", "Applications", "System", "Library", "Volumes", "private"):
        return
    if directory in ("/Users", "/Applications", "/System", "/Library", "/opt", "/usr", "/private"):
        return
    for existing in items:
        if existing == directory:
            return
    items.append(directory)


def app_guesses():
    home = os.path.expanduser("~")
    return [
        "/Applications/DeepSeek Harness.app",
        os.path.join(home, "Applications", "DeepSeek Harness.app"),
        "/Applications/DSH Desktop.app",
        os.path.join(home, "Applications", "DSH Desktop.app"),
    ]


def get_search_dirs(dsh_source):
    dirs = []
    if dsh_source:
        current = os.path.dirname(dsh_source)
        for _ in range(3):
            if not current:
                break
            add_unique_dir(dirs, current)
            parent = os.path.dirname(current)
            if not parent or parent == current:
                break
            current = parent
    home = os.path.expanduser("~")
    add_unique_dir(dirs, os.path.join(home, "Library", "Application Support", "DeepSeek Harness"))
    for app in app_guesses():
        if not os.path.isdir(app):
            continue
        add_unique_dir(dirs, app)
        add_unique_dir(dirs, os.path.join(app, "Contents", "MacOS"))
        add_unique_dir(dirs, os.path.join(app, "Contents", "Resources"))
    return dirs


def find_relative_file(dsh_source, relative_names):
    for directory in get_search_dirs(dsh_source):
        for rel in relative_names:
            path = os.path.join(directory, rel)
            if os.path.isfile(path):
                return path
    return None


def enrich_path():
    home = os.path.expanduser("~")
    extras = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        os.path.join(home, ".local", "bin"),
        os.path.join(home, "bin"),
        os.path.join(home, ".volta", "bin"),
        os.path.join(home, "Library", "pnpm"),
        os.path.join(home, ".npm-global", "bin"),
    ]
    parts = [part for part in os.environ.get("PATH", "").split(os.pathsep) if part]
    seen = set(parts)
    for extra in extras:
        if extra and extra not in seen and os.path.isdir(extra):
            parts.append(extra)
            seen.add(extra)
    os.environ["PATH"] = os.pathsep.join(parts)


def find_git():
    found = shutil.which("git")
    if found and os.path.isfile(found):
        return found
    if os.path.isfile("/usr/bin/git") and os.access("/usr/bin/git", os.X_OK):
        return "/usr/bin/git"
    return None


def find_tool(name):
    found = shutil.which(name)
    if found and os.path.isfile(found):
        return found
    fallback = "/usr/bin/" + name
    if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
        return fallback
    return None


def find_dsh():
    found = shutil.which("dsh")
    if found and os.path.isfile(found):
        return found
    home = os.path.expanduser("~")
    for path in (
        "/opt/homebrew/bin/dsh",
        "/usr/local/bin/dsh",
        os.path.join(home, ".local", "bin", "dsh"),
        os.path.join(home, "bin", "dsh"),
        os.path.join(home, ".npm-global", "bin", "dsh"),
    ):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def find_node(dsh_source):
    found = shutil.which("node")
    if found and os.path.isfile(found):
        return found
    return find_relative_file(dsh_source, (
        "node",
        "bin/node",
        "node/bin/node",
        "nodejs/bin/node",
        "runtime/node",
        "runtime/bin/node",
        "resources/node/bin/node",
        "Resources/node/bin/node",
    ))


def find_pnpm(dsh_source):
    found = shutil.which("pnpm")
    if found and os.path.isfile(found):
        return {"exe": found, "prefix": [], "label": found}
    home = os.path.expanduser("~")
    for path in (
        "/opt/homebrew/bin/pnpm",
        "/usr/local/bin/pnpm",
        os.path.join(home, "Library", "pnpm", "pnpm"),
        os.path.join(home, ".local", "share", "pnpm", "pnpm"),
        os.path.join(home, ".local", "bin", "pnpm"),
        os.path.join(home, ".npm-global", "bin", "pnpm"),
    ):
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return {"exe": path, "prefix": [], "label": path}
    near = find_relative_file(dsh_source, (
        "pnpm",
        "bin/pnpm",
        "node/bin/pnpm",
        "nodejs/bin/pnpm",
        "runtime/bin/pnpm",
        "resources/node/bin/pnpm",
        "Resources/node/bin/pnpm",
    ))
    if near:
        return {"exe": near, "prefix": [], "label": near}

    core = shutil.which("corepack")
    if core and os.path.isfile(core):
        return {"exe": core, "prefix": ["pnpm"], "label": core + " pnpm"}
    node = find_node(dsh_source)
    if node:
        node_dir = os.path.dirname(node)
        for rel in (
            "corepack",
            "bin/corepack",
            "../lib/node_modules/corepack/dist/corepack.js",
            "node_modules/corepack/dist/corepack.js",
            "node_modules/corepack/corepack.js",
        ):
            js = os.path.normpath(os.path.join(node_dir, rel))
            if not os.path.isfile(js):
                continue
            if js.endswith(".js"):
                return {"exe": node, "prefix": [js, "pnpm"], "label": "node " + js + " pnpm"}
            return {"exe": js, "prefix": ["pnpm"], "label": js + " pnpm"}
    npx = shutil.which("npx")
    if npx and os.path.isfile(npx):
        return {"exe": npx, "prefix": ["--yes", "pnpm"], "label": npx + " --yes pnpm"}
    return None


def add_path_front(directory):
    if not directory or not os.path.isdir(directory):
        return
    os.environ["PATH"] = directory + os.pathsep + os.environ.get("PATH", "")


def invoke_pnpm_install(directory, dsh_source, dry_run):
    found = find_pnpm(dsh_source)
    if not found:
        raise InstallError(
            "找不到 pnpm。package.json 若已改好，请在该目录手动执行 pnpm install：\n"
            "  " + directory + "\n"
            "成功标志是 node_modules/dsh-purge/package.json 。也可以用官方 dsh 自带的 Node / pnpm 后再运行本脚本。"
        )
    node = find_node(dsh_source)
    if node:
        add_path_front(os.path.dirname(node))
    say("      使用 " + found["label"])
    if dry_run:
        say("      [dry-run] 不执行 pnpm install")
        return
    args = [found["exe"]]
    for item in found["prefix"]:
        if item:
            args.append(item)
    args.append("install")
    previous = os.getcwd()
    os.chdir(directory)
    try:
        cwd = os.path.realpath(os.getcwd())
        want = os.path.realpath(directory)
        if os.path.normcase(cwd) != os.path.normcase(want):
            raise InstallError("工作目录不对: " + cwd)
        say("      开始 pnpm install，可能要几分钟")
        result = subprocess.run(args)
        if result.returncode != 0:
            raise InstallError(
                "pnpm install 失败，退出码 "
                + str(result.returncode)
                + " 。package.json 已改好，可在此目录重试： "
                + directory
            )
    finally:
        os.chdir(previous)


def assert_plugin_dest(dest):
    dest = os.path.abspath(dest)
    if os.path.basename(dest) != "dsh-purge":
        raise InstallError("拒绝操作意外目录: " + dest)
    norm = dest.replace("\\", "/").rstrip("/")
    if not norm.endswith("/plugins/dsh-purge"):
        raise InstallError("插件路径必须是 plugins/dsh-purge ： " + dest)
    return dest


def assert_plugin_package(dest):
    pkg = os.path.join(dest, "package.json")
    if not os.path.isfile(pkg):
        raise InstallError("插件目录缺少 package.json: " + dest)
    obj = load_json(read_text_file(pkg)["text"], "插件 package.json 无法解析: " + dest)
    if obj.get("name") != "dsh-purge":
        raise InstallError(
            "插件 package.json 的 name 是 " + ps_str(obj.get("name")) + "，必须是 dsh-purge。目录: " + dest
        )


def save_url(url, outfile):
    curl = find_tool("curl")
    if not curl:
        raise InstallError("找不到 curl，无法下载")
    result = subprocess.run([
        curl, "-fsSL", "--max-time", "180",
        "-A", "dsh-purge-macos-install",
        "-o", outfile, url,
    ])
    if result.returncode != 0:
        raise InstallError("下载失败，退出码 " + str(result.returncode))


def install_plugin_from_archive(dest):
    dest = assert_plugin_dest(dest)
    repo_web = GIT_REPO[:-4] if GIT_REPO.endswith(".git") else GIT_REPO
    urls = [
        repo_web + "/archive/refs/heads/master.tar.gz",
        repo_web + "/archive/refs/heads/main.tar.gz",
        repo_web + "/archive/refs/heads/master.zip",
        repo_web + "/archive/refs/heads/main.zip",
    ]
    work = tempfile.mkdtemp(prefix="dsh-purge-dl-")
    try:
        archive = None
        for url in urls:
            out = os.path.join(work, os.path.basename(url))
            say("      下载 " + url)
            try:
                save_url(url, out)
                if os.path.isfile(out) and os.path.getsize(out) > 200:
                    archive = out
                    break
            except Exception as exc:
                say("      这次失败: " + str(exc))
        if not archive:
            raise InstallError("git clone 和压缩包下载都失败了")
        extract = os.path.join(work, "extract")
        os.makedirs(extract, exist_ok=True)
        tar = find_tool("tar")
        if not tar:
            raise InstallError("找不到 tar，无法解压")
        result = subprocess.run([tar, "-xf", archive, "-C", extract])
        if result.returncode != 0:
            raise InstallError("解压失败，退出码 " + str(result.returncode))
        found = None
        for name in os.listdir(extract):
            directory = os.path.join(extract, name)
            if not os.path.isdir(directory):
                continue
            pkg = os.path.join(directory, "package.json")
            if not os.path.isfile(pkg):
                continue
            try:
                obj = json.loads(read_text_file(pkg)["text"])
            except Exception:
                continue
            if obj.get("name") == "dsh-purge":
                found = directory
                break
        if not found:
            raise InstallError("压缩包里没有 name 为 dsh-purge 的目录")
        parent = os.path.dirname(dest)
        os.makedirs(parent, exist_ok=True)
        shutil.move(found, dest)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def install_plugin_fresh(dest):
    dest = assert_plugin_dest(dest)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    if os.path.exists(dest):
        raise InstallError("目标已存在: " + dest)
    git = find_git()
    ok = False
    if git:
        say("      git clone --depth 1 " + GIT_REPO)
        result = subprocess.run([git, "clone", "--depth", "1", GIT_REPO, dest])
        if result.returncode == 0:
            ok = True
        else:
            say("      git clone 失败，改为下载压缩包。")
    else:
        say("      找不到 git，改为下载压缩包。")
    if not ok:
        if os.path.basename(dest) == "dsh-purge" and os.path.isdir(dest):
            shutil.rmtree(dest)
        install_plugin_from_archive(dest)
    assert_plugin_package(dest)


def normalize_url(url):
    if not url:
        return ""
    value = url.strip().rstrip("/")
    if value.endswith(".git"):
        value = value[:-4]
    if value.startswith("git@github.com:"):
        value = "https://github.com/" + value[len("git@github.com:"):]
    return value.lower()


def sync_plugin(dest, dry_run):
    dest = assert_plugin_dest(dest)
    if not os.path.exists(dest):
        if dry_run:
            say("      [dry-run] 将克隆到 " + dest)
            say("      " + GIT_REPO)
            return
        install_plugin_fresh(dest)
        say("      插件已放到 " + dest)
        return
    pkg = os.path.join(dest, "package.json")
    if not os.path.isfile(pkg):
        raise InstallError("已有目录但没有 package.json，请先移走再运行： " + dest)
    obj = load_json(read_text_file(pkg)["text"], "插件 package.json 无法解析: " + dest)
    if obj.get("name") != "dsh-purge":
        raise InstallError(
            "已有目录的 name 是 " + ps_str(obj.get("name")) + "，不是 dsh-purge。请移走后再运行： " + dest
        )
    git_dir = os.path.join(dest, ".git")
    if not os.path.exists(git_dir):
        say("      插件目录已在，且不是 git 仓库，保留现有文件")
        return
    git = find_git()
    if not git:
        say("      插件目录已在，但找不到 git，跳过更新")
        return
    result = subprocess.run(
        [git, "-C", dest, "remote", "get-url", "origin"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    remote = result.stdout.strip() if result.returncode == 0 else ""
    want = normalize_url(GIT_REPO)
    have = normalize_url(remote)
    if have == want:
        if dry_run:
            say("      [dry-run] 将 git pull --ff-only")
            return
        say("      git pull --ff-only")
        pulled = subprocess.run([git, "-C", dest, "pull", "--ff-only"])
        if pulled.returncode != 0:
            say("      git pull 失败，继续使用当前文件")
        assert_plugin_package(dest)
        return
    say("      现有远程: " + remote)
    say("      本次要装: " + GIT_REPO)
    if dry_run:
        say("      [dry-run] 正式运行时会询问是否备份旧目录并重新克隆")
        return
    if not sys.stdin.isatty():
        say("      当前不是交互终端，保留现有插件目录")
        assert_plugin_package(dest)
        return
    ans = input("      输入 Y 备份旧目录并重新克隆，其它键保留现有目录")
    if ans == "Y" or ans == "y":
        bak = dest + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.move(dest, bak)
        say("      旧目录已改名为 " + bak)
        install_plugin_fresh(dest)
    else:
        say("      保留现有插件目录")
    assert_plugin_package(dest)


def test_home_layout(path):
    profiles = os.path.join(path, "profiles")
    if not os.path.isdir(profiles):
        return "没有 profiles 目录"
    any_pkg = False
    try:
        names = os.listdir(profiles)
    except OSError:
        return "没有 profiles 目录"
    for name in names:
        directory = os.path.join(profiles, name)
        if os.path.isdir(directory) and os.path.isfile(os.path.join(directory, "package.json")):
            any_pkg = True
            break
    if not any_pkg:
        return "profiles 下没有 package.json"
    return ""


def add_home_candidate(checked, valid, path, reason):
    path = clean_path(path)
    if not path:
        return
    for item in checked:
        if os.path.normcase(item["path"]) == os.path.normcase(path):
            return
    note = test_home_layout(path)
    ok = note == ""
    if ok:
        note = "可用"
    item = {"path": path, "reason": reason, "ok": ok, "note": note}
    checked.append(item)
    if ok:
        valid.append(item)


def get_home_candidates():
    global DSH_SOURCE
    checked = []
    valid = []
    env_home = os.environ.get("DSH_HOME", "")
    if env_home.strip():
        before = len(checked)
        add_home_candidate(checked, valid, env_home, "环境变量 DSH_HOME")
        if len(checked) > before and not checked[-1]["ok"]:
            item = checked[-1]
            say("环境变量 DSH_HOME 不能用: " + item["path"] + " （" + item["note"] + "），继续找其它位置")
    DSH_SOURCE = find_dsh()
    if DSH_SOURCE:
        directory = os.path.dirname(DSH_SOURCE)
        add_home_candidate(checked, valid, os.path.join(directory, ".dsh"), "dsh 所在目录旁的 .dsh")
        parent = os.path.dirname(directory)
        if parent and parent != directory:
            add_home_candidate(checked, valid, os.path.join(parent, ".dsh"), "dsh 上一级旁的 .dsh")
            grand = os.path.dirname(parent)
            if grand and grand != parent:
                add_home_candidate(checked, valid, os.path.join(grand, ".dsh"), "dsh 上两级旁的 .dsh")
    home = os.path.expanduser("~")
    add_home_candidate(checked, valid, os.path.join(home, ".dsh"), "用户目录 .dsh")
    add_home_candidate(
        checked, valid,
        os.path.join(home, "Library", "Application Support", "DeepSeek Harness", "dsh-home"),
        "Application Support dsh-home",
    )
    return {"checked": checked, "valid": valid}


def get_profile_status(dsh_home):
    result = []
    for name in ("web", "desktop"):
        directory = os.path.join(dsh_home, "profiles", name)
        pkg = os.path.join(directory, "package.json")
        status = {"name": name, "dir": directory, "pkg": pkg, "ok": False, "reason": ""}
        if not os.path.isfile(pkg):
            status["reason"] = "没有 package.json"
            result.append(status)
            continue
        try:
            obj = json.loads(read_text_file(pkg)["text"])
        except Exception:
            status["reason"] = "package.json 无法解析"
            result.append(status)
            continue
        expect = "dsh-profile-web" if name == "web" else "dsh-profile-desktop"
        if obj.get("name") != expect:
            status["reason"] = "name 是 " + ps_str(obj.get("name")) + "，期望 " + expect
            result.append(status)
            continue
        status["ok"] = True
        status["reason"] = expect
        result.append(status)
    return result


def read_choice(prompt, valid):
    if not sys.stdin.isatty():
        raise InstallError("需要在终端里选择，或在命令行写上 web / desktop / both 和 DSH_HOME 路径")
    allowed = [str(item) for item in valid]
    while True:
        try:
            ans = input(prompt)
        except EOFError as exc:
            raise InstallError("已取消") from exc
        if ans is None:
            raise InstallError("已取消")
        ans = ans.strip()
        if ans in ("q", "Q"):
            raise InstallError("已取消")
        if ans in allowed:
            return ans
        say("      请输入 " + " / ".join(allowed) + "，或 q 退出")


def show_manual_steps(dsh_home, names):
    say("")
    say("文件已经放好。下面这些脚本不会代做:")
    say("  1. 完全退出刚装的那个宿主，再打开。")
    for name in names:
        if name == "web":
            say("     Web: 关掉 dsh web 再开。")
        if name == "desktop":
            say("     桌面: 用菜单栏彻底退出 DeepSeek Harness，再打开。只关窗口不够。")
    say("  2. 在这个宿主里点会话标题旁的 dsh-purge，进入「清洗」，点「应用」。")
    say("     宿主的设置页里没有这个按钮。")
    say("  3. 「应用」成功后会自动重启一次。没点「应用」不会重启。")
    say("本次改的是: " + ", ".join(names))
    say("DSH_HOME:")
    say("  " + dsh_home)


def show_usage():
    say("用法:")
    say("  bash scripts/install-macos.sh")
    say("  bash scripts/install-macos.sh web")
    say("  bash scripts/install-macos.sh desktop")
    say("  bash scripts/install-macos.sh both")
    say('  bash scripts/install-macos.sh web "$HOME/.dsh"')
    say("  bash scripts/install-macos.sh --dry-run")
    say("  bash scripts/install-macos.sh --self-test")
    say("仓库: " + GIT_REPO)
    say("只改你选中的 profile。不点「应用」，也不重启宿主。")


def invoke_self_test():
    if GIT_REPO != "https://github.com/niuniuqiu/dsh-purge.git":
        raise InstallError("自检: 仓库地址不对")
    if DEP_VALUE != "file:../../plugins/dsh-purge":
        raise InstallError("自检: 依赖路径不对")

    nl = "\r\n"
    pretty = (
        "{" + nl
        + '  "name": "dsh-profile-web",' + nl
        + '  "description": "保持中文",' + nl
        + '  "private": true,' + nl
        + '  "version": "1.2.3",' + nl
        + '  "dependencies": {' + nl
        + '    "@deepseek-ai/dsh-base": "1.0.0",' + nl
        + '    "@deepseek-ai/dsh-web-app": "1.0.0"' + nl
        + "  }," + nl
        + '  "dsh": {' + nl
        + '    "profile": {' + nl
        + '      "bundles": [' + nl
        + '        "@deepseek-ai/dsh-base",' + nl
        + '        "@deepseek-ai/dsh-web-app"' + nl
        + "      ]," + nl
        + '      "patchReload": "live"' + nl
        + "    }" + nl
        + "  }" + nl
        + "}" + nl
    )
    once = update_profile_text(pretty)
    twice = update_profile_text(once)
    if twice != once:
        raise InstallError("自检: 第二次运行不应再改 package.json")
    if "保持中文" not in once:
        raise InstallError("自检: 中文丢失")
    if '"patchReload": "live"' not in once:
        raise InstallError("自检: patchReload 被改写")
    if '"version": "1.2.3"' not in once:
        raise InstallError("自检: version 被改写")
    if '"@deepseek-ai/dsh-web-app": "1.0.0"' not in once:
        raise InstallError("自检: 原依赖被改")
    obj = json.loads(once)
    if ps_str(obj["dependencies"]["dsh-purge"]) != DEP_VALUE:
        raise InstallError("自检: 依赖路径不对")
    bundles = get_bundle_list(obj)
    if len(bundles) != 3 or bundles[2] != "dsh-purge":
        raise InstallError("自检: bundle 没有加在末尾")

    desk = (
        "{" + nl
        + '  "name": "dsh-profile-desktop",' + nl
        + '  "dependencies": {' + nl
        + '    "@deepseek-ai/dsh-base": "2.0.0"' + nl
        + "  }," + nl
        + '  "dsh": {' + nl
        + '    "profile": {' + nl
        + '      "bundles": [' + nl
        + '        "@deepseek-ai/dsh-base"' + nl
        + "      ]," + nl
        + '      "patchReload": "live"' + nl
        + "    }" + nl
        + "  }" + nl
        + "}" + nl
    )
    dout = update_profile_text(desk)
    if "dsh-web-app" in dout:
        raise InstallError("自检: 桌面端被写进了 dsh-web-app")

    wrong = '{"name":"dsh-profile-desktop","dependencies":{"@deepseek-ai/dsh-base":"2.0.0","dsh-purge":"9.9.9"},"dsh":{"profile":{"bundles":["dsh-purge","@deepseek-ai/dsh-base"],"patchReload":"live"}}}'
    wout = update_profile_text(wrong)
    if '"dsh-purge"' in wout and "9.9.9" in wout:
        raise InstallError("自检: 旧版本号还在")
    if (
        '"dsh-purge": "file:../../plugins/dsh-purge"' not in wout
        and '"dsh-purge":"file:../../plugins/dsh-purge"' not in wout
    ):
        raise InstallError("自检: 没有改成 file: 相对路径")
    if '"bundles":["dsh-purge","@deepseek-ai/dsh-base"]' not in wout:
        raise InstallError("自检: 已有 bundle 被重排")
    if '"patchReload":"live"' not in wout:
        raise InstallError("自检: patchReload 变了")
    if '"@deepseek-ai/dsh-base":"2.0.0"' not in wout:
        raise InstallError("自检: 原依赖变了")

    empty_dep = '{"name":"dsh-profile-web","dependencies":{},"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base"],"patchReload":"live"}}}'
    update_profile_text(empty_dep)
    empty_bun = '{"name":"dsh-profile-web","dependencies":{"a":"1"},"dsh":{"profile":{"bundles":[],"patchReload":"live"}}}'
    update_profile_text(empty_bun)

    lf = "{\n  \"name\": \"dsh-profile-web\",\n  \"dependencies\": {\n    \"a\": \"1\"\n  },\n  \"dsh\": { \"profile\": { \"bundles\": [ \"only\" ], \"patchReload\": \"live\" } }\n}\n"
    if "\r" in lf:
        raise InstallError("自检: LF 样本构造错了")
    lout = update_profile_text(lf)
    if "\r" in lout:
        raise InstallError("自检: LF 文件被改成了 CRLF")

    bad = '{"name":"dsh-profile-web","dependencies":{"a":"1"},"dsh":{"profile":{"patchReload":"live"}}}'
    threw = False
    try:
        update_profile_text(bad)
    except InstallError as exc:
        threw = True
        if "bundles" not in str(exc):
            raise
    if not threw:
        raise InstallError("自检: 缺少 bundles 时应该停止")

    tmp = os.path.join(
        tempfile.gettempdir(),
        "dsh-purge-jsontest-" + str(os.getpid()) + ".json",
    )
    sample = '{"description":"保持中文"}'
    try:
        write_text_file(tmp, sample, {"enc": "utf-8", "bom": False})
        back = read_text_file(tmp)
        if back["text"] != sample:
            raise InstallError("自检: 编码往返失败")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def parse_args(argv):
    self_test_only = False
    dry_run = False
    profile_arg = ""
    home_arg = ""
    for raw in argv:
        if raw is None:
            continue
        arg = str(raw).strip()
        if not arg:
            continue
        if arg in ("-h", "--help", "/?", "/help"):
            return {"help": True}
        if arg in ("--self-test", "-self-test"):
            self_test_only = True
            continue
        if arg in ("--dry-run", "-dry-run"):
            dry_run = True
            continue
        token = ""
        if not any(ch in arg for ch in "\\/:"):
            low = arg.lower()
            if low in ("web", "desktop", "both"):
                token = low
        if token:
            if profile_arg:
                raise InstallError("profile 指定了两次: " + profile_arg + " 和 " + token)
            profile_arg = token
            continue
        if home_arg:
            raise InstallError("无法识别参数: " + arg)
        home_arg = arg
    return {
        "help": False,
        "self_test": self_test_only,
        "dry_run": dry_run,
        "profile": profile_arg,
        "home": home_arg,
    }


def main():
    parsed = parse_args(sys.argv[1:])
    if parsed["help"]:
        show_usage()
        return

    invoke_self_test()
    say("JSON 补丁自检通过")
    if parsed["self_test"]:
        return
    if sys.platform != "darwin":
        raise InstallError("这个安装只支持 macOS")

    say("")
    say("dsh-purge macOS 安装")
    say("仓库: " + GIT_REPO)
    if parsed["dry_run"]:
        say("当前是 dry-run，不会改文件，也不会执行 pnpm install")
    say("")

    enrich_path()
    home_arg = parsed["home"]
    if home_arg:
        home_arg = clean_path(home_arg)
        note = test_home_layout(home_arg)
        if note:
            raise InstallError("指定的 DSH_HOME 不能用: " + home_arg + " （" + note + "）")
        picked = {"path": home_arg, "reason": "命令行指定"}
        get_home_candidates()
    else:
        found = get_home_candidates()
        valid = found["valid"]
        if not valid:
            say("没有找到可用的 DSH_HOME。检查过:")
            for item in found["checked"]:
                flag = "可用" if item["ok"] else "跳过"
                say("  [" + flag + "] " + item["path"])
                say("         " + item["reason"] + " / " + item["note"])
            say('可以手动指定: bash scripts/install-macos.sh web "$HOME/.dsh"')
            raise InstallError("没有找到可用的 DSH_HOME")
        env_pick = None
        for item in valid:
            if item["reason"] == "环境变量 DSH_HOME":
                env_pick = item
                break
        if env_pick:
            picked = env_pick
        elif len(valid) == 1:
            picked = valid[0]
        else:
            say("找到多个 DSH_HOME。请选你实际启动的那一份:")
            number = 1
            for item in valid:
                say("  [" + str(number) + "] " + item["path"])
                say("      " + item["reason"])
                for status in get_profile_status(item["path"]):
                    mark = "可用" if status["ok"] else "不可用"
                    say("      profile " + status["name"] + ": " + mark + " （" + status["reason"] + "）")
                number += 1
            choice = read_choice("      输入序号，q 退出", [str(n) for n in range(1, len(valid) + 1)])
            picked = valid[int(choice) - 1]
        if len(valid) > 1:
            say("本次使用: " + picked["path"])
            say("未使用的其它主目录:")
            for item in valid:
                if item["path"] == picked["path"]:
                    continue
                say("  " + item["path"] + " （" + item["reason"] + "）")
            say("如果实际启动的不是这一份，请重跑并写上路径。")

    dsh_home = picked["path"]
    say("[1/4] DSH_HOME")
    say("      " + dsh_home)
    say("      来源: " + picked["reason"])

    stats = get_profile_status(dsh_home)
    ok_names = [status["name"] for status in stats if status["ok"]]
    for status in stats:
        if not status["ok"]:
            say("      跳过 " + status["name"] + ": " + status["reason"])

    profile_arg = parsed["profile"]
    selected = []
    if profile_arg == "both":
        selected = list(ok_names)
        if not selected:
            raise InstallError("web 和 desktop 都不可用")
    elif profile_arg:
        hit = None
        for status in stats:
            if status["name"] == profile_arg:
                hit = status
        if not hit or not hit["ok"]:
            why = hit["reason"] if hit else "不存在"
            raise InstallError("profile " + profile_arg + " 不可用: " + why)
        selected = [profile_arg]
    elif len(ok_names) == 1:
        selected = [ok_names[0]]
    elif len(ok_names) == 2:
        say("这个主目录里 Web 和桌面端都在。手册要求只改正在用的那个宿主。")
        say("  [1] 只装 web")
        say("  [2] 只装 desktop")
        say("  [3] 两个都装")
        which = read_choice("      输入 1 / 2 / 3，q 退出", ["1", "2", "3"])
        if which == "1":
            selected = ["web"]
        elif which == "2":
            selected = ["desktop"]
        else:
            selected = ["web", "desktop"]
    else:
        raise InstallError("没有可用的 web 或 desktop profile")

    say("      将处理: " + ", ".join(selected))
    say("")
    say("[2/4] 插件目录")
    dest = os.path.join(dsh_home, "plugins", "dsh-purge")
    say("      " + dest)
    sync_plugin(dest, parsed["dry_run"])

    done = []
    for name in selected:
        directory = os.path.join(dsh_home, "profiles", name)
        pkg = os.path.join(directory, "package.json")
        say("")
        say("[3/4] 修改 " + name)
        say("      " + pkg)
        try:
            update_profile_file(pkg, parsed["dry_run"])
            say("")
            say("[4/4] pnpm install (" + name + ")")
            say("      目录 " + directory)
            invoke_pnpm_install(directory, DSH_SOURCE, parsed["dry_run"])
            if not parsed["dry_run"]:
                marker = os.path.join(directory, "node_modules", "dsh-purge", "package.json")
                if not os.path.isfile(marker):
                    raise InstallError(
                        "没有找到成功标志 " + marker + " 。请检查 dependencies 里的 file:../../plugins/dsh-purge 。"
                    )
                marker_obj = json.loads(read_text_file(marker)["text"])
                if marker_obj.get("name") != "dsh-purge":
                    raise InstallError("node_modules 里的 name 不是 dsh-purge")
                say("      成功标志: " + marker)
            done.append(name)
        except Exception:
            if done:
                say("这些 profile 已经处理完: " + ", ".join(done))
            raise

    if parsed["dry_run"]:
        say("")
        say("dry-run 结束，没有修改文件。")
        return
    show_manual_steps(dsh_home, done)


def report_failure(exc):
    say("")
    say("安装失败:")
    say(type(exc).__name__ + ": " + str(exc))
    cause = getattr(exc, "__cause__", None)
    if cause:
        say("原因: " + str(cause))
    if BACKUPS:
        say("已留下的备份（这是修改前的 package.json）:")
        for bak in BACKUPS:
            say("  " + bak)
        say("package.json 若已改好，修好 pnpm 后直接重跑即可，不必先还原。")


if __name__ == "__main__":
    try:
        main()
    except InstallError as exc:
        report_failure(exc)
        sys.exit(1)
    except KeyboardInterrupt:
        say("")
        say("已取消")
        sys.exit(130)
    except Exception as exc:
        report_failure(exc)
        traceback.print_exc()
        sys.exit(1)
END_DSH_PURGE_PY
