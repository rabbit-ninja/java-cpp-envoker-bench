# java-cpp-envoker

I wanted to know how much time Java actually adds when it calls into C++, so I built
the smallest thing that could tell me.

There's a tiny Java 21 HTTP service and four C++20 operations (`add`, `sub`, `mul`, `div`).
You send it `op`, `a`, `b` and a `mode`, it calls the C++ code that way and tells you
the result and where the time went. The modes:

| mode      | how Java reaches the C++ code                                        |
|-----------|----------------------------------------------------------------------|
| `process` | starts the standalone binary `/app/bin/<op>` (default)               |
| `jni`     | hand-written JNI glue (`cpp/jni_ops.cpp`) -> `libops.so`             |
| `jna`     | JNA direct mapping, no glue code -> `libops.so`                      |
| `swig`    | SWIG-generated JNI glue (from `cpp/ops.i`) -> `libops.so`            |

Nothing gets installed on your machine. The source lives here, and the build and run happen in the container.

## Architecture

```
  host                     container (podman, eclipse-temurin:21-jdk + g++ + swig + JNA)
 ──────                   ─────────────────────────────────────────────────────────────────────
                          ┌──────────────────────── Java 21 (Main.java) ──────────────────────┐
 curl ── GET /calc ─────▶ │ parse + validate op/a/b/mode/n                                     │
   ?op=add&a=2&b=3        │                                                                    │
   &mode=jni&n=1000000    │  mode=process        mode=jni         mode=jna        mode=swig    │
                          │  ProcessBuilder      Jni.add()        Jna.op_add()    SwigOps.op_add│
                          └──────┬──────────────────┬────────────────┬───────────────┬─────────┘
                                 │ fork/exec        │ JNI            │ JNA (JNI      │ JNI
                                 ▼                  ▼                │  dispatch)    ▼
                          ┌──────────────┐   ┌──────────────┐        │        ┌──────────────┐
                          │ /app/bin/add │   │libjniops.so  │        │        │libswigops.so │
                          │ (static exe) │   │(hand-written)│        │        │(generated)   │
                          └──────────────┘   └──────┬───────┘        │        └──────┬───────┘
                                                    ▼                ▼               ▼
                                             ┌────────────────────────────────────────────┐
                                             │ libops.so: op_add op_sub op_mul op_div      │
                                             └────────────────────────────────────────────┘
 ◀── JSON ──────────────  { result, timings_ms: {...} }
```

Build (inside the image, see `Dockerfile`), all with `g++ -std=c++20 -O3`:

```
 cpp/{add,sub,mul,div}.cpp ── -static ──────────────────────▶ /app/bin/{add,sub,mul,div}
 cpp/{add,sub,mul,div}.cpp ── -shared -DOPS_LIB ────────────▶ /app/lib/libops.so
 cpp/bench_native.cpp ─────── links libops.so ──────────────▶ /app/bin/bench_native
 cpp/jni_ops.cpp ──────────── -shared, links libops.so ─────▶ /app/lib/libjniops.so
 cpp/ops.i ── swig -java ──▶ gen/ops_wrap.cxx ── -shared ───▶ /app/lib/libswigops.so
                         └─▶ gen/SwigOps*.java ─┐
 java/Main.java ────────────────────────────────┴── javac ──▶ /app/classes
```

## How it works

- Each C++ file has one function (`op_add` and so on, declared in `cpp/ops.h`). The same file
  builds two ways: a standalone static binary for `process`, and with `-DOPS_LIB` it goes into
  `libops.so` for `jni`, `jna` and `swig`. That way every mode runs exactly the same function,
  which is the whole point of the comparison.
- `Main.java` is just the JDK's built-in `com.sun.net.httpserver` on port 8080. No framework.
  It checks the input first (known op, real numbers, no divide by zero, sane `n`) and then calls C++.
- One in-process call is a few nanoseconds, way below what a timer can measure on its own, so
  `jni`/`jna`/`swig` take an `n` and loop that many times.
- `bench_native` is the baseline for those: plain C++ calling the same `libops.so` function `n` times.
- JNA comes from Ubuntu's apt repo (`libjna-java`), so I don't have to download and pin a jar.

### Timings (all in ms)

`mode=process`:

| field           | what it measures                                               |
|-----------------|----------------------------------------------------------------|
| `parse`         | Java parsing and validating the query string                   |
| `spawn`         | `ProcessBuilder.start()` (fork/exec of the C++ binary)         |
| `wait`          | C++ process run time plus Java reading its stdout and exit code |
| `cpp_compute`   | the arithmetic itself, measured inside C++                     |
| `total`         | the whole Java handler, from request in to JSON ready          |
| `java_overhead` | `total - cpp_compute`                                          |

`mode=jni|jna|swig`:

| field      | what it measures                         |
|------------|------------------------------------------|
| `parse`    | Java parsing and validating the query    |
| `calls`    | all `n` calls                            |
| `per_call` | `calls / n`                              |
| `total`    | the whole Java handler                   |

## Run

```bash
podman compose up --build -d
```

```bash
podman compose logs -f
```

## Use (once the container is up)

From the host:

```bash
curl "http://localhost:8080/calc?op=add&a=2&b=3"
```

```bash
curl "http://localhost:8080/calc?op=add&a=2&b=3&mode=jni"
```

```bash
curl "http://localhost:8080/calc?op=div&a=10&b=4&mode=jna&n=1000000"
```

```bash
curl "http://localhost:8080/calc?op=mul&a=6&b=7&mode=swig&n=1000000"
```

Example responses:

```json
{"op":"add","a":"2","b":"3","mode":"process","result":"5.0","timings_ms":{"parse":0.029250,"spawn":0.801293,"wait":0.122500,"cpp_compute":0.000083,"total":0.962085,"java_overhead":0.962002}}
{"op":"add","a":"2","b":"3","mode":"jni","n":1000,"result":"5.0","timings_ms":{"parse":0.071209,"calls":0.540043,"per_call":0.000540043,"total":0.874961}}
```

Errors return HTTP 400, for example `op=div&a=1&b=0`, `op=pow` or `mode=x`.

Native C++ baselines, from inside the container:

```bash
podman compose exec app bash -c 'time /app/bin/mul 6 7'
```

```bash
podman compose exec app /app/bin/bench_native mul 6 7 1000000
```

## Container resources (CPU / RAM)

The container is capped at **4 CPUs and 4 GB RAM** by default (see `compose.yaml`). I pinned it
so numbers from different runs are comparable.

That cap sits inside the podman VM, which is the real ceiling. Mine has 6 CPUs, 8 GB RAM and
a 60 GB disk on arm64 (aarch64). Check yours:

```bash
podman machine inspect --format '{{.Resources.CPUs}} cpus, {{.Resources.Memory}} MiB'
```

See what the container and the JVM actually get:

```bash
podman compose exec app sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max'
```

```bash
podman compose exec app java -XshowSettings:system -version
```

`cpu.max` reads `400000 100000`, which means 4 CPUs (quota / period). `memory.max` is in bytes.

**Change the container limits.** Set `CPUS` and `MEMORY` when starting it. No rebuild needed:

```bash
CPUS=2 MEMORY=1g podman compose up -d
```

Running `podman compose up -d` again without them goes back to 4 CPUs / 4 GB. To change the
defaults for good, edit the `cpus` and `mem_limit` lines in `compose.yaml`.

**Change the VM itself** (if you want more than the VM has). This restarts podman, so any
running containers stop:

```bash
podman machine stop
```

```bash
podman machine set --cpus 6 --memory 8192
```

```bash
podman machine start
```

Note: the benchmark calls are single-threaded, so the CPU count barely changes the numbers.
What does matter is not running anything heavy on the machine while it runs.

## Benchmark

It prints the environment first (OS, VM, container limits, Java / g++ / SWIG / JNA versions),
then runs all four ops in every mode, after warm-up. The container can't see the host's chip
name, so if you share results, add it yourself (`sysctl -n machdep.cpu.brand_string` on a Mac). Arguments: process iterations (default 200)
and in-process calls (default 1000000).

```bash
podman compose exec app /app/bench.sh
```

```bash
podman compose exec app /app/bench.sh 500 10000000
```

```
Environment
  OS         : Ubuntu 26.04.1 LTS (container), kernel 6.19.7-200.fc43.aarch64 (VM), aarch64
  VM         : Apple, 6 CPUs, 7905 MiB RAM
  Container  : 4 CPUs, 4096 MiB RAM
  Java       : OpenJDK 64-Bit Server VM Temurin-21.0.12.1+1 (build 21.0.12.1+1-LTS, mixed mode, sharing)
  C++        : g++ (Ubuntu 15.2.0-16ubuntu1) 15.2.0, -std=c++20 -O3
  SWIG       : 4.4.0   JNA: 5.15.0-1build1

1) Process per call: Java starts the C++ binary. Averages over 200 warm calls (a=6, b=3). Times in ms.
+-----+------------+-----------+---------------+------------+
| op  | native cpp |  via java | java overhead | overhead % |
+-----+------------+-----------+---------------+------------+
| add |      0.237 |     0.421 |         0.185 |      78.2% |
| sub |      0.221 |     0.416 |         0.195 |      88.5% |
| mul |      0.215 |     0.379 |         0.164 |      76.2% |
| div |      0.233 |     0.374 |         0.141 |      60.7% |
+-----+------------+-----------+---------------+------------+

2) In-process call: same C++ function, no process. Averages over 1000000 warm calls. Times in ns per call.
+-----+--------+------------------+------------------+------------------+
| op  | native |  JNI (+overhead) |  JNA (+overhead) | SWIG (+overhead) |
+-----+--------+------------------+------------------+------------------+
| add |   0.98 |   4.47 (  +3.49) |  37.04 ( +36.06) |   3.47 (  +2.49) |
| sub |   0.68 |   4.20 (  +3.51) |  36.56 ( +35.88) |   3.25 (  +2.57) |
| mul |   0.67 |   3.16 (  +2.49) |  35.77 ( +35.11) |   3.07 (  +2.40) |
| div |   0.71 |   3.08 (  +2.36) |  37.00 ( +36.29) |   3.34 (  +2.63) |
+-----+--------+------------------+------------------+------------------+
```

- Table 1: `native cpp` runs the binary directly, `via java` is the same binary started from Java.
  `java overhead` is the difference.
- Table 2: `native` is C++ calling the `libops.so` function. Each binding's `(+overhead)` is
  what that Java call path adds per call.

What I take from it:

- JNI and SWIG cost about the same (~3 ns a call). Makes sense, SWIG just generates JNI glue for you.
- JNA is roughly 10x slower (~36 ns), even in direct mapping mode, because it converts arguments at runtime.
  Still fine unless you're calling it millions of times a second.
- Starting a process for every call (~0.2 ms) is tens of thousands of times worse than any of
  them. Don't do that on a hot path.
- The first few calls after a restart are much slower while the JIT warms up. That's why
  `bench.sh` warms up before measuring. A single cold `curl` will look bad.

Smoke test, pass/fail only, no timings (all ops, all modes, error cases):

```bash
podman compose exec app /app/test.sh
```

Stop:

```bash
podman compose down
```
