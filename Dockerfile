FROM eclipse-temurin:21-jdk
# libjna-java: JNA from Ubuntu's signed repo instead of a raw jar download
RUN apt-get update && apt-get install -y --no-install-recommends g++ swig libjna-java curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY cpp/ cpp/
COPY java/ java/
COPY test.sh bench.sh ./
ENV CXX="g++ -std=c++20 -O3" JNI_INC="-I/opt/java/openjdk/include -I/opt/java/openjdk/include/linux" LINK_OPS="-Llib -lops -Wl,-rpath,/app/lib"
RUN mkdir bin lib gen \
 && for op in add sub mul div; do $CXX -static -o bin/$op cpp/$op.cpp; done \
 && $CXX -fPIC -shared -DOPS_LIB -o lib/libops.so cpp/add.cpp cpp/sub.cpp cpp/mul.cpp cpp/div.cpp \
 && $CXX -o bin/bench_native cpp/bench_native.cpp $LINK_OPS \
 && $CXX -fPIC -shared $JNI_INC -o lib/libjniops.so cpp/jni_ops.cpp $LINK_OPS \
 && swig -java -c++ -outdir gen -o gen/ops_wrap.cxx cpp/ops.i \
 && $CXX -fPIC -shared -Icpp $JNI_INC -o lib/libswigops.so gen/ops_wrap.cxx $LINK_OPS \
 && javac --release 21 -cp /usr/share/java/jna.jar -d classes java/Main.java gen/*.java
EXPOSE 8080
CMD ["java", "-cp", "classes:/usr/share/java/jna.jar", "-Djava.library.path=/app/lib", "-Djna.library.path=/app/lib", "Main"]
