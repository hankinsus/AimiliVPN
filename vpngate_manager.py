import importlib.machinery
import importlib.util
import os
import sys


def _load(name):
    here = os.path.dirname(os.path.abspath(__file__))
    for suffix in importlib.machinery.EXTENSION_SUFFIXES:
        path = os.path.join(here, name + suffix)
        if os.path.exists(path):
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            return module
    sys.stderr.write("AimiliVPN 程序模块缺失，请运行 bash scripts/select_core.sh 或重新安装。\n")
    raise SystemExit(1)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    _load("vpngate_manager").main()
else:
    _m = _load("vpngate_manager")
    globals().update({k: v for k, v in vars(_m).items() if not k.startswith("__")})
