import com.sun.jna.Native;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.function.DoubleBinaryOperator;

// JNI: hand-written C++ glue in cpp/jni_ops.cpp (libjniops.so) -> libops.so
class Jni {
    static { System.loadLibrary("jniops"); }
    static native double add(double a, double b);
    static native double sub(double a, double b);
    static native double mul(double a, double b);
    static native double div(double a, double b);
}

// JNA direct mapping (JNA's fastest mode): binds straight to libops.so, no C glue
class Jna {
    static { Native.register("ops"); }
    static native double op_add(double a, double b);
    static native double op_sub(double a, double b);
    static native double op_mul(double a, double b);
    static native double op_div(double a, double b);
}

public class Main {
    static final Set<String> OPS = Set.of("add", "sub", "mul", "div");

    // SWIG's generated SwigOps/SwigOpsJNI classes don't load their own library
    static { System.loadLibrary("swigops"); }

    // all 12 go through one call site, so every mode pays the same ~1ns for the indirect call
    static final Map<String, DoubleBinaryOperator> IN_PROCESS = Map.ofEntries(
            Map.entry("jni/add", Jni::add), Map.entry("jni/sub", Jni::sub),
            Map.entry("jni/mul", Jni::mul), Map.entry("jni/div", Jni::div),
            Map.entry("jna/add", Jna::op_add), Map.entry("jna/sub", Jna::op_sub),
            Map.entry("jna/mul", Jna::op_mul), Map.entry("jna/div", Jna::op_div),
            Map.entry("swig/add", SwigOps::op_add), Map.entry("swig/sub", SwigOps::op_sub),
            Map.entry("swig/mul", SwigOps::op_mul), Map.entry("swig/div", SwigOps::op_div));

    public static void main(String[] args) throws Exception {
        var server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/calc", ex -> {
            long t0 = System.nanoTime();
            int status = 200;
            String body;
            try {
                Map<String, String> q = query(ex.getRequestURI().getRawQuery());
                String op = q.get("op"), a = q.get("a"), b = q.get("b"), mode = q.getOrDefault("mode", "process");
                // op picks the binary path, so it must be one of the four
                if (!OPS.contains(op)) throw new IllegalArgumentException("op must be one of " + OPS);
                if (a == null || b == null) throw new IllegalArgumentException("a and b are required");
                double x = Double.parseDouble(a), y = Double.parseDouble(b);
                if (op.equals("div") && y == 0) throw new IllegalArgumentException("division by zero");
                long t1 = System.nanoTime();

                if (mode.equals("process")) {
                    Process p = new ProcessBuilder("/app/bin/" + op, a, b).redirectErrorStream(true).start();
                    long t2 = System.nanoTime();

                    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
                    int exit = p.waitFor();
                    long t3 = System.nanoTime();
                    if (exit != 0) throw new IllegalArgumentException(out);

                    String[] parts = out.split(" ");
                    double result = Double.parseDouble(parts[0]);
                    long cppNs = Long.parseLong(parts[1]);
                    long total = System.nanoTime() - t0;
                    body = """
                            {"op":"%s","a":"%s","b":"%s","mode":"process","result":"%s","timings_ms":{"parse":%.6f,"spawn":%.6f,"wait":%.6f,"cpp_compute":%.6f,"total":%.6f,"java_overhead":%.6f}}
                            """.formatted(op, a, b, result, (t1 - t0) / 1e6, (t2 - t1) / 1e6, (t3 - t2) / 1e6,
                            cppNs / 1e6, total / 1e6, (total - cppNs) / 1e6);
                } else {
                    DoubleBinaryOperator f = IN_PROCESS.get(mode + "/" + op);
                    if (f == null) throw new IllegalArgumentException("mode must be process, jni, jna or swig");
                    int n = Integer.parseInt(q.getOrDefault("n", "1"));
                    if (n < 1 || n > 100_000_000) throw new IllegalArgumentException("n must be 1..100000000");

                    double result = 0;
                    long t2 = System.nanoTime();
                    for (int i = 0; i < n; i++) result = f.applyAsDouble(x, y);
                    long t3 = System.nanoTime();
                    long total = System.nanoTime() - t0;
                    body = """
                            {"op":"%s","a":"%s","b":"%s","mode":"%s","n":%d,"result":"%s","timings_ms":{"parse":%.6f,"calls":%.6f,"per_call":%.9f,"total":%.6f}}
                            """.formatted(op, a, b, mode, n, result, (t1 - t0) / 1e6, (t3 - t2) / 1e6,
                            (t3 - t2) / 1e6 / n, total / 1e6);
                }
            } catch (Exception e) {
                status = 400;
                body = "{\"error\":\"" + String.valueOf(e.getMessage()).replace('"', '\'') + "\"}\n";
            }
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", "application/json");
            ex.sendResponseHeaders(status, bytes.length);
            ex.getResponseBody().write(bytes);
            ex.close();
        });
        server.start();
        System.out.println("listening on :8080  try /calc?op=add&a=2&b=3&mode=jni");
    }

    static Map<String, String> query(String raw) {
        Map<String, String> m = new HashMap<>();
        if (raw == null) return m;
        for (String kv : raw.split("&")) {
            String[] p = kv.split("=", 2);
            m.put(URLDecoder.decode(p[0], StandardCharsets.UTF_8), p.length > 1 ? URLDecoder.decode(p[1], StandardCharsets.UTF_8) : "");
        }
        return m;
    }
}
