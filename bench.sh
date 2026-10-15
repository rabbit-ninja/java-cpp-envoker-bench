#!/bin/bash
# Benchmark: each C++ binary run directly vs through the Java service. Run inside the container.
# usage: /app/bench.sh [process_iterations] [in_process_calls]   (defaults 200 and 1000000)
set -e
n=${1:-200}; calls=${2:-1000000}; a=6; b=3
url="localhost:8080/calc"
tmp=$(mktemp); rows=$(mktemp); rows2=$(mktemp)

# environment, so results can be compared across machines
. /etc/os-release
read -r quota period < /sys/fs/cgroup/cpu.max
mem=$(cat /sys/fs/cgroup/memory.max)
echo "Environment"
echo "  OS         : $PRETTY_NAME (container), kernel $(uname -r) (VM), $(uname -m)"
echo "  VM         : $(lscpu | awk -F': +' '/^Vendor ID/ {v=$2} /^Model name/ {m=$2} /^CPU\(s\)/ {c=$2} END {print v (m != "-" ? " " m : "") ", " c " CPUs"}'), $(awk '/MemTotal/ {printf "%d MiB", $2 / 1024}' /proc/meminfo) RAM"
echo "  Container  : $([ "$quota" = max ] && echo "no CPU limit" || echo "$((quota / period)) CPUs"), $([ "$mem" = max ] && echo "no memory limit" || echo "$((mem / 1024 / 1024)) MiB RAM")"
echo "  Java       : $(java -version 2>&1 | tail -1)"
echo "  C++        : $(g++ --version | head -1), -std=c++20 -O3"
echo "  SWIG       : $(swig -version | awk '/Version/ {print $3}')   JNA: $(dpkg-query -W -f='${Version}' libjna-java)"
echo

for op in add sub mul div; do
  for i in $(seq 50); do curl -sf "$url?op=$op&a=$a&b=$b" >/dev/null; done  # JIT warm-up

  s=$EPOCHREALTIME
  for i in $(seq "$n"); do /app/bin/$op $a $b >/dev/null; done
  e=$EPOCHREALTIME

  : > "$tmp"
  for i in $(seq "$n"); do curl -sf "$url?op=$op&a=$a&b=$b" >> "$tmp"; done

  # per-call averages in ms: native = bash loop wall time / n, java = mean of the reported "total"
  awk -F'"total":' -v op="$op" -v s="$s" -v e="$e" -v n="$n" '
    { split($2, v, ","); sum += v[1] }
    END { printf "%s %f %f\n", op, (e - s) * 1000 / n, sum / n }' "$tmp" >> "$rows"
done

echo "1) Process per call: Java starts the C++ binary. Averages over $n warm calls (a=$a, b=$b). Times in ms."
awk '
  function line() { print "+-----+------------+-----------+---------------+------------+" }
  BEGIN { line(); printf "| %-3s | %10s | %9s | %13s | %10s |\n", "op", "native cpp", "via java", "java overhead", "overhead %"; line() }
  { printf "| %-3s | %10.3f | %9.3f | %13.3f | %9.1f%% |\n", $1, $2, $3, $3 - $2, ($3 - $2) * 100 / $2 }
  END { line() }' "$rows"
cat <<'LEGEND'
native cpp    = run the C++ binary directly: process start + math + exit
via java      = same binary called from the Java service (HTTP round trip not included)
java overhead = via java - native cpp
LEGEND

# 2) In-process: Java calls the libops.so function directly through JNI, JNA, SWIG
for op in add sub mul div; do
  /app/bin/bench_native $op $a $b "$calls" >/dev/null  # warm-up
  row="$op $(/app/bin/bench_native $op $a $b "$calls")"
  for mode in jni jna swig; do
    q="$url?op=$op&a=$a&b=$b&mode=$mode&n=$calls"
    curl -sf "$q" >/dev/null; curl -sf "$q" >/dev/null  # warm-up: JIT-compiles the loop and native stubs
    ms=$(curl -sf "$q" | sed -E 's/.*"calls":([0-9.]+).*/\1/')
    row="$row $(awk -v ms="$ms" -v n="$calls" 'BEGIN { printf "%f", ms * 1e6 / n }')"
  done
  echo "$row" >> "$rows2"
done

echo
echo "2) In-process call: same C++ function, no process. Averages over $calls warm calls. Times in ns per call."
awk '
  function line() { print "+-----+--------+------------------+------------------+------------------+" }
  BEGIN { line(); printf "| %-3s | %6s | %16s | %16s | %16s |\n", "op", "native", "JNI (+overhead)", "JNA (+overhead)", "SWIG (+overhead)"; line() }
  { printf "| %-3s | %6.2f | %6.2f (%+7.2f) | %6.2f (%+7.2f) | %6.2f (%+7.2f) |\n", $1, $2, $3, $3 - $2, $4, $4 - $2, $5, $5 - $2 }
  END { line() }' "$rows2"
cat <<'LEGEND'
native     = C++ calling the libops.so function in a loop
JNI        = hand-written JNI glue (cpp/jni_ops.cpp)
JNA        = JNA direct mapping, no glue code
SWIG       = SWIG-generated JNI glue
(+overhead) = that binding minus native, i.e. what the Java call adds
LEGEND
rm -f "$tmp" "$rows" "$rows2"
