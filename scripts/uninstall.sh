#!/usr/bin/env bash
# ml uninstall 的入口：卸载逻辑在 install.sh 里，这里直接转过去（ml 已经问过确认，不再重复问）。
D=/opt/aimilivpn
if [ ! -f "$D/install.sh" ]; then
    echo "未找到 $D/install.sh，卸载未执行。"
    exit 1
fi
AIMILI_YES=1 exec bash "$D/install.sh" uninstall
