#!/bin/bash
# Smoke test: run inside the container while the service is up.
fail=0
check() { # name, query, expected substring
  out=$(curl -s "localhost:8080/calc?$2")
  if [[ $out == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: $out"; fail=1; fi
}
check add "op=add&a=2&b=3"    '"result":"5.0"'
check sub "op=sub&a=2&b=3"    '"result":"-1.0"'
check mul "op=mul&a=6&b=7"    '"result":"42.0"'
check div "op=div&a=10&b=4"   '"result":"2.5"'
check div0 "op=div&a=1&b=0"   'division by zero'
check badop "op=pow&a=1&b=2"  'op must be one of'
check nan "op=add&a=x&b=2"    '"error"'
for m in jni jna swig; do
  check "$m add" "op=add&a=2&b=3&mode=$m"   '"result":"5.0"'
  check "$m div" "op=div&a=10&b=4&mode=$m"  '"result":"2.5"'
  check "$m div0" "op=div&a=1&b=0&mode=$m"  'division by zero'
done
check badmode "op=add&a=1&b=2&mode=x" 'mode must be'
exit $fail
