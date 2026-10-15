#pragma once
// The four operations as plain C symbols, so JNI, JNA and SWIG all call the same functions in libops.so.
extern "C" {
double op_add(double a, double b);
double op_sub(double a, double b);
double op_mul(double a, double b);
double op_div(double a, double b);
}
