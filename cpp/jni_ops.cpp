// Hand-written JNI glue for class Jni (java/Main.java) -> libops.so
#include <jni.h>
#include "ops.h"

extern "C" {
JNIEXPORT jdouble JNICALL Java_Jni_add(JNIEnv*, jclass, jdouble a, jdouble b) { return op_add(a, b); }
JNIEXPORT jdouble JNICALL Java_Jni_sub(JNIEnv*, jclass, jdouble a, jdouble b) { return op_sub(a, b); }
JNIEXPORT jdouble JNICALL Java_Jni_mul(JNIEnv*, jclass, jdouble a, jdouble b) { return op_mul(a, b); }
JNIEXPORT jdouble JNICALL Java_Jni_div(JNIEnv*, jclass, jdouble a, jdouble b) { return op_div(a, b); }
}
