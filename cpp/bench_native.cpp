// Native baseline: C++ calling the same libops.so function n times. Prints ns per call.
// usage: bench_native <add|sub|mul|div> <a> <b> <n>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "ops.h"

int main(int argc, char** argv) {
    if (argc != 5) { std::fprintf(stderr, "usage: bench_native <op> <a> <b> <n>\n"); return 2; }
    const char* op = argv[1];
    double (*f)(double, double) = !std::strcmp(op, "add") ? op_add : !std::strcmp(op, "sub") ? op_sub
                                : !std::strcmp(op, "mul") ? op_mul : !std::strcmp(op, "div") ? op_div : nullptr;
    long n = std::atol(argv[4]);
    if (!f || n < 1) { std::fprintf(stderr, "bad op or n\n"); return 2; }
    double a = std::strtod(argv[2], nullptr), b = std::strtod(argv[3], nullptr);
    volatile double sink;  // keeps every call; the functions live in libops.so so they can't be inlined
    auto t0 = std::chrono::steady_clock::now();
    for (long i = 0; i < n; i++) sink = f(a, b);
    auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
    std::printf("%.3f\n", static_cast<double>(ns) / n);
}
