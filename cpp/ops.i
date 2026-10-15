// SWIG generates SwigOps.java, SwigOpsJNI.java and the C++ wrapper from ops.h
%module SwigOps
%{
#include "ops.h"
%}
%include "ops.h"
