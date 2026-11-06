#!/usr/bin/env bash
# check-cpu-model.sh — LoongArch CPU 型号识别补丁的回归检查
#
# 直接从 noctalia 源码抽取 cpuInfoKeyRank / isPureNumber / readCpuModel，
# 编译成最小 harness，喂入真实 /proc/cpuinfo 与 x86 / LoongArch / MIPS / ARM
# 样本并断言输出。上游改了函数名或补丁丢失时，这里会直接失败。
#
# 用法：
#   NOCTALIA_DIR=$HOME/build/noctalia loong64/scripts/check-cpu-model.sh
#   CXX 可覆盖编译器（默认 /opt/gcc-14.4.0/bin/g++，需支持 C++20 ranges）
set -euo pipefail

NOCTALIA_DIR=${NOCTALIA_DIR:-"$HOME/build/noctalia"}
CXX=${CXX:-/opt/gcc-14.4.0/bin/g++}

python3 - "$NOCTALIA_DIR/src/system/hardware_info.cpp" "$CXX" <<'PY'
import re
import subprocess
import sys
import tempfile
from pathlib import Path

src_path, cxx = sys.argv[1], sys.argv[2]
src = Path(src_path).read_text()
try:
    start = src.index('  int cpuInfoKeyRank')
    end = src.index('  std::string_view shortVendorPrefix')
except ValueError:
    sys.exit('FAIL: 源码里找不到 CPU 解析函数（补丁未打，或上游改了函数名）')

# 只替换两处外部依赖：输入文件路径、i18n 兜底字符串；解析逻辑保持源码原文。
block = (src[start:end]
         .replace('std::ifstream file{"/proc/cpuinfo"}', 'std::ifstream file{g_cpuinfoPath}')
         .replace('i18n::tr("system.hardware.unknown-cpu")', 'std::string{"UNKNOWN"}'))

harness = r'''#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <string>
#include <string_view>
#include <utility>
namespace StringUtils {
  inline std::string trim(std::string_view s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.remove_prefix(1);
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.remove_suffix(1);
    return std::string(s);
  }
}
std::string g_cpuinfoPath;
''' + block + r'''
int main(int argc, char** argv) {
  g_cpuinfoPath = argv[1];
  std::cout << readCpuModel() << "\n";
}
'''

real = Path('/proc/cpuinfo').read_text() if Path('/proc/cpuinfo').exists() else ''
real_match = re.search(r'^\s*model\s*name\s*:\s*(.+)$', real, re.I | re.M)
cases = [
    ('real /proc/cpuinfo', real, real_match.group(1).strip() if real_match else 'UNKNOWN'),
    ('x86 model name',
     'processor\t: 0\nvendor_id\t: GenuineIntel\n'
     'model name\t: Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz\n',
     'Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz'),
    ('LoongArch Model Name',
     'system type\t\t: generic-loongson-machine\nprocessor\t\t: 0\n'
     'CPU Family\t\t: Loongson-64bit\nModel Name\t\t: Loongson-3A5000\n',
     'Loongson-3A5000'),
    ('MIPS cpu model',
     'processor\t\t: 0\ncpu model\t\t: Loongson-3A5000 V0.4  FPU V0.1\n',
     'Loongson-3A5000 V0.4  FPU V0.1'),
    ('ARM Hardware',
     'processor\t: 0\nHardware\t: BCM2711\nRevision\t: c03112\n',
     'BCM2711'),
    ('ARM Processor only',
     'Processor\t: ARMv8 Processor rev 3 (v8l)\nprocessor\t: 0\nBogoMIPS\t: 108.00\n',
     'ARMv8 Processor rev 3 (v8l)'),
    ('no model key -> fallback',
     'processor\t: 0\nBogoMIPS\t: 4600.00\n',
     'UNKNOWN'),
]

with tempfile.TemporaryDirectory(prefix='noctalia-cpu-') as tmp:
    t = Path(tmp)
    h = t / 'harness.cpp'
    h.write_text(harness)
    binary = t / 'harness'
    compile_result = subprocess.run(
        [cxx, '-std=c++23', '-O0', '-o', str(binary), str(h)],
        capture_output=True, text=True)
    if compile_result.returncode:
        sys.exit('FAIL: harness 编译失败\n' + compile_result.stderr[:3000])

    failures = 0
    for name, content, want in cases:
        sample = t / 'cpuinfo.txt'
        sample.write_text(content)
        got = subprocess.run([str(binary), str(sample)],
                             capture_output=True, text=True).stdout.strip()
        ok = got == want
        failures += not ok
        print(f'{"OK  " if ok else "FAIL"} {name:26s} -> {got}'
              + ('' if ok else f'  (期望: {want})'))
    print(f'结果: {len(cases) - failures}/{len(cases)} 通过')
    sys.exit(1 if failures else 0)
PY
