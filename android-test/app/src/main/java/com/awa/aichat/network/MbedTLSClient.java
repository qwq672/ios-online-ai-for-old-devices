package com.awa.aichat.network;

import android.util.Log;

/**
 * MbedTLSClient — Android JNI wrapper for mbedTLS HTTP/TLS client
 * v261116-7: mbedTLS 双选项 — Android 2.3 上系统不支持 TLS 1.2，用 mbedTLS 自带栈
 *
 * 用法（替代 HttpURLConnection）:
 *   MbedTLSClient client = new MbedTLSClient();
 *   if (client.connect("api.openai.com", 443)) {
 *       client.write(requestBytes);
 *       byte[] buf = new byte[8192];
 *       int n;
 *       while ((n = client.read(buf)) > 0) {
 *           // 处理 SSE 数据
 *       }
 *   }
 *   client.close();
 *
 * 仅当 native 库编译时 HAS_MBEDTLS=1 才可用，否则 hasMbedTLS() 返回 false。
 * NetworkService 在 hasMbedTLS()==false 时自动 fallback 到 HttpURLConnection。
 */
public class MbedTLSClient {

    private static final String TAG = "AIAnyWhere/MbedTLS";
    private long nativePtr;
    // v261116-8: available 必须是 static — static 块 + hasMbedTLS() 都是静态访问
    private static boolean available;

    static {
        try {
            System.loadLibrary("aianywhere-native");
            available = nativeAvailable();
            Log.i(TAG, "libaianywhere-native loaded, mbedTLS available: " + available);
        } catch (UnsatisfiedLinkError e) {
            available = false;
            Log.w(TAG, "libaianywhere-native not available: " + e.getMessage());
        }
    }

    public MbedTLSClient() {
        if (available) {
            nativePtr = nativeCreate();
            if (nativePtr == 0) {
                // native 创建失败 — 不修改静态 available，只在本次实例不可用
                nativePtr = 0;
            }
        }
    }

    /** mbedTLS 是否可用（取决于 native 库编译时是否启用） */
    public static boolean hasMbedTLS() {
        return available;
    }

    /** 建立 TCP + TLS 连接 */
    public boolean connect(String host, int port) {
        if (!available || nativePtr == 0) return false;
        int ret = nativeConnect(nativePtr, host, port);
        if (ret != 0) {
            Log.e(TAG, "connect failed: " + ret);
            return false;
        }
        return true;
    }

    /** 写数据到 TLS 连接 */
    public int write(byte[] data) {
        if (!available || nativePtr == 0) return -1;
        return nativeWrite(nativePtr, data);
    }

    /** 从 TLS 读数据，返回读到的字节数（0 = EOF，负数 = 错误） */
    public int read(byte[] buffer) {
        if (!available || nativePtr == 0) return -1;
        return nativeRead(nativePtr, buffer);
    }

    /** 取消（让 ssl_read/write 循环退出） */
    public void cancel() {
        if (available && nativePtr != 0) {
            nativeCancel(nativePtr);
        }
    }

    /** 关闭并释放资源 */
    public void close() {
        if (available && nativePtr != 0) {
            nativeDestroy(nativePtr);
            nativePtr = 0;
        }
    }

    @Override
    protected void finalize() throws Throwable {
        try { close(); } finally { super.finalize(); }
    }

    // === Native 方法 ===
    private static native boolean nativeAvailable();
    private native long nativeCreate();
    private native void nativeDestroy(long ptr);
    private native void nativeCancel(long ptr);
    private native int nativeConnect(long ptr, String host, int port);
    private native int nativeWrite(long ptr, byte[] data);
    private native int nativeRead(long ptr, byte[] buffer);
}
