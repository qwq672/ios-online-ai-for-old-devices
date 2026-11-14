package com.awa.aichat.network;

/**
 * SSEParser — Java wrapper for shared C SSE parser
 * v261113: 跨平台共享 C 层 — Android JNI 桥接
 *
 * 用法：
 *   SSEParser parser = new SSEParser(new SSEParser.Callback() {
 *       public void onData(String data, boolean done) {
 *           // 处理 SSE data 事件
 *       }
 *   });
 *   parser.feed(rawBytes);    // 收到网络数据时调
 *   parser.destroy();         // 结束时调
 *
 * 底层调用 shared/sse.c（和 iOS 共享同一份 C 代码）
 */
public class SSEParser {

    public interface Callback {
        void onData(String data, boolean done);
    }

    private long nativePtr;
    private long callbackPtr;
    private Callback callback;

    static {
        System.loadLibrary("aianywhere-native");
    }

    public SSEParser(Callback callback) {
        this.callback = callback;
        // nativeCreate 返回 packed long：高 32 位 = parser ptr，低 32 位 = callback_data ptr
        long packed = nativeCreate(callback);
        this.nativePtr = (packed >> 32) & 0xFFFFFFFFL;
        this.callbackPtr = packed & 0xFFFFFFFFL;
    }

    public void feed(byte[] data) {
        if (nativePtr != 0 && data != null && data.length > 0) {
            nativeFeed(nativePtr, data);
        }
    }

    public void reset() {
        if (nativePtr != 0) {
            nativeReset(nativePtr);
        }
    }

    public void destroy() {
        if (nativePtr != 0) {
            nativeDestroyWithCallback(nativePtr, callbackPtr);
            nativePtr = 0;
        }
    }

    @Override
    protected void finalize() throws Throwable {
        try {
            destroy();
        } finally {
            super.finalize();
        }
    }

    // --- Native methods ---
    private native long nativeCreate(Callback callback);
    private native void nativeFeed(long ptr, byte[] data);
    private native void nativeReset(long ptr);
    private native void nativeDestroy(long ptr);
    private native void nativeDestroyWithCallback(long ptr, long callbackPtr);
}
