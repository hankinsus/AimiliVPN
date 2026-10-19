#!/usr/bin/env bash
set -e
cd "${1:-$(dirname "$(readlink -f "$0")")/..}"
arch=$(uname -m)
case "$arch" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac
suf=$(python3 -c "import sysconfig;print(sysconfig.get_config_var('EXT_SUFFIX'))")
pyv=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
if ! ls "core/${arch}/"*"${suf}" >/dev/null 2>&1 || [ ! -f "core/${arch}/vpngate_manager${suf}" ]; then
    echo "错误: 没有适合本机的程序模块（架构 ${arch}，Python ${pyv}）。支持 x86_64 / aarch64，Python 3.9–3.13。" >&2
    exit 1
fi
rm -f ./*.cpython-*.so ./*.abi3.so
for src in "core/${arch}/"*"${suf}"; do cp -f "$src" ./; done
echo "  -> 程序模块: ${arch} Python ${pyv}"
