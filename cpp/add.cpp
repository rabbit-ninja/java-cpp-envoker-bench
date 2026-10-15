#include <chrono>
#include <cstdio>
#include <cstdlib>
#include "ops.h"

double op_add(double a, double b) { return a + b; }

#ifndef OPS_LIB  // with -DOPS_LIB this file goes into libops.so (no main)
int main(int argc, char** argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: add <a> <b>\n"); return 2; }
    char *endA, *endB;
    double a = std::strtod(argv[1], &endA), b = std::strtod(argv[2], &endB);
    if (*argv[1] == 0 || *argv[2] == 0 || *endA || *endB) { std::fprintf(stderr, "a and b must be numbers\n"); return 2; }
    auto t0 = std::chrono::steady_clock::now();
    volatile double r = op_add(a, b);  // volatile so -O3 can't fold the op away
    auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
    std::printf("%.17g %lld\n", static_cast<double>(r), static_cast<long long>(ns));
}
#endif
