package com.awa.aichat.network;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.awa.aichat.model.Message;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;

/**
 * NetworkService — SSE streaming chat completions for Android 2.3+.
 *
 * Mirrors the iOS app's approach: manual HttpURLConnection + line-by-line
 * SSE parsing. No OkHttp, no external deps — pure Android SDK.
 *
 * v0.2 fixes:
 *  - cancel() no longer surfaces an "IOException" error to the UI.
 *    The catch block checks `cancelled` and returns silently.
 *  - Non-SSE JSON responses are now handled (some OpenAI-compatible
 *    servers ignore stream=true and return a plain JSON body).
 *  - max_tokens is sent when configured (>0).
 *  - User-Agent header added (some providers reject requests without one).
 *  - OutputStream is NOT closed before getResponseCode() — closing it
 *    on certain Android 2.3 devices caused the request to be sent
 *    with a truncated body. We just flush and let the framework close.
 *  - Fixed-length streaming mode for the request body (avoids buffering
 *    the whole body in memory — important when we later add image upload).
 */
public class NetworkService {

    private static final String TAG = "NetworkService";
    private static final int TIMEOUT = 120000; // 2 min

    // v0.3: Android 2.3 默认只支持 TLS 1.0，OpenAI/Zhipu 等 API 要求 TLS 1.2+。
    // v0.4: 强化 TLS — 自定义 SSLSocketFactory 包装默认 factory，在每个 socket
    // 上强制 setEnabledProtocols(["TLSv1.2", "TLSv1.1", "TLSv1"])。
    // SSLContext.getInstance("TLSv1.2") 在某些 2.3 OEM build 上静默失败
    // （返回不支持 TLS 1.2 的实现），自定义 factory 确保协议列表正确传递。
    static {
        try {
            javax.net.ssl.SSLContext sc = javax.net.ssl.SSLContext.getInstance("TLS");
            sc.init(null, null, null);
            javax.net.ssl.HttpsURLConnection.setDefaultSSLSocketFactory(
                new TLSSocketFactory(sc.getSocketFactory()));
            Log.i(TAG, "TLS 1.2 enforced via custom socket factory");
        } catch (Exception e) {
            Log.w(TAG, "TLS init failed: " + e.getMessage());
        }
    }

    public interface Listener {
        void onChunk(String fullText);
        void onThinking(String thinkingText);
        void onFinish(String fullText, String thinking);
        void onError(String message);
    }

    private Listener listener;
    private volatile boolean cancelled = false;
    private volatile HttpURLConnection connection;  // v261103-35 fix #11: volatile 防 cancel 竞态
    private Thread streamThread;

    // Accumulated text + thinking
    private final StringBuilder accumulated = new StringBuilder();
    private final StringBuilder thinkingAccumulated = new StringBuilder();

    public void setListener(Listener l) { this.listener = l; }

    public void streamChat(final String baseURL, final String apiKey,
                           final String model, final List<Message> messages,
                           final String systemPrompt, final float temperature,
                           final int maxTokens, final boolean stream) {
        cancelled = false;
        accumulated.setLength(0);
        thinkingAccumulated.setLength(0);

        final List<Message> msgsCopy = new ArrayList<Message>(messages);
        final String sysCopy = systemPrompt;

        streamThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    doStream(baseURL, apiKey, model, msgsCopy, sysCopy,
                             temperature, maxTokens, stream);
                } catch (Exception e) {
                    // v0.2: if the user cancelled, swallow the exception
                    // (disconnecting the connection surfaces as an
                    // IOException — that's expected, not an error).
                    if (cancelled) return;
                    Log.e(TAG, "stream error", e);
                    notifyError(friendlyError(e));
                }
            }
        }, "AIChat-Stream");
        streamThread.start();
    }

    /** Convenience overload — defaults maxTokens=0 (don't send), stream=true. */
    public void streamChat(String baseURL, String apiKey,
                           String model, List<Message> messages,
                           String systemPrompt, float temperature) {
        streamChat(baseURL, apiKey, model, messages, systemPrompt,
                   temperature, 0, true);
    }

    public void cancel() {
        cancelled = true;
        if (connection != null) {
            try { connection.disconnect(); } catch (Exception ignored) {}
        }
    }

    private void doStream(String baseURL, String apiKey, String model,
                          List<Message> messages, String systemPrompt,
                          float temperature, int maxTokens, boolean stream)
            throws Exception {

        // Build endpoint URL
        String endpoint = baseURL;
        if (endpoint == null || endpoint.length() == 0) {
            throw new IllegalArgumentException("baseURL is empty");
        }
        if (endpoint.endsWith("/")) endpoint = endpoint.substring(0, endpoint.length() - 1);
        if (endpoint.endsWith("/v1")) {
            endpoint += "/chat/completions";
        } else if (!endpoint.endsWith("/chat/completions")) {
            endpoint += "/v1/chat/completions";
        }

        // Build messages JSON array
        JSONArray msgsArr = new JSONArray();
        if (systemPrompt != null && systemPrompt.length() > 0) {
            msgsArr.put(new JSONObject().put("role", "system").put("content", systemPrompt));
        }
        for (Message m : messages) {
            // Skip the placeholder "…" assistant message — it has no real content yet.
            if (m.isAssistant() && (m.content == null || m.content.length() == 0 || m.content.equals("…"))) {
                continue;
            }
            msgsArr.put(new JSONObject().put("role", m.roleName()).put("content", m.content));
        }

        // Build request body
        JSONObject body = new JSONObject();
        body.put("model", model);
        body.put("messages", msgsArr);
        body.put("stream", stream);
        body.put("temperature", (double) temperature);
        if (maxTokens > 0) {
            body.put("max_tokens", maxTokens);
        }

        String bodyStr = body.toString();
        byte[] bodyBytes = bodyStr.getBytes("UTF-8");

        // Create connection
        URL url = new URL(endpoint);
        connection = (HttpURLConnection) url.openConnection();
        connection.setRequestMethod("POST");
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Accept", "text/event-stream");
        // v0.2: some providers reject requests without a User-Agent.
        connection.setRequestProperty("User-Agent", "AIAnyWhere/0.2 Android");
        if (apiKey != null && apiKey.length() > 0) {
            connection.setRequestProperty("Authorization", "Bearer " + apiKey);
        }
        connection.setConnectTimeout(TIMEOUT);
        connection.setReadTimeout(TIMEOUT);
        connection.setDoOutput(true);
        // v0.2: fixed-length streaming mode — we already know the body
        // size. This avoids buffering the whole body in memory and lets
        // the framework write it directly to the socket.
        connection.setFixedLengthStreamingMode(bodyBytes.length);

        // Write body — do NOT close the OutputStream before reading the
        // response; on Android 2.3 some OEM builds will send a truncated
        // body if you close too early. Flush is enough.
        OutputStream os = connection.getOutputStream();
        os.write(bodyBytes);
        os.flush();

        int code = connection.getResponseCode();
        if (code < 200 || code >= 300) {
            String errBody = readStream(connection.getErrorStream());
            notifyError("HTTP " + code + ": " + truncate(errBody, 500));
            return;
        }

        // Peek at content type — if it's JSON (not event-stream), the
        // server ignored stream=true and returned a plain JSON body.
        String contentType = connection.getContentType();
        boolean isSSE = contentType != null && contentType.toLowerCase().contains("event-stream");

        if (!isSSE || !stream) {
            // Plain JSON response — parse the whole body.
            String respBody = readStream(connection.getInputStream());
            parseNonStreamJson(respBody);
            if (cancelled) return;
            notifyFinish(accumulated.toString(), thinkingAccumulated.toString());
            return;
        }

        // Read SSE stream
        InputStream is = connection.getInputStream();
        BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));
        String line;
        boolean sawAnyData = false;

        while (!cancelled && (line = reader.readLine()) != null) {
            line = line.trim();
            if (line.length() == 0) continue;
            if (!line.startsWith("data:")) continue;

            String payload = line.substring(5).trim();
            if (payload.equals("[DONE]")) {
                sawAnyData = true;
                break;
            }
            if (payload.length() == 0) continue;

            try {
                sawAnyData = true;
                JSONObject obj = new JSONObject(payload);
                JSONArray choices = obj.optJSONArray("choices");
                if (choices == null || choices.length() == 0) continue;

                JSONObject choice = choices.getJSONObject(0);
                JSONObject delta = choice.optJSONObject("delta");
                // Some servers send "message" instead of "delta" (non-stream
                // shape sneaking through). Be defensive.
                if (delta == null) delta = choice.optJSONObject("message");

                if (delta != null) {
                    // Content — v0.3: Android org.json optString(key, "") 在
                    // JSON 值为 null 时返回字符串 "null"（不是 fallback ""），
                    // 导致截图里出现的 "nullnullnull…" — 用 safeStr 过滤。
                    String content = safeStr(delta, "content");
                    if (content.length() > 0) {
                        accumulated.append(content);
                        notifyChunk(accumulated.toString());
                    }

                    // Reasoning / thinking — try every known field name.
                    String reasoning = safeStr(delta, "reasoning_content");
                    if (reasoning.length() == 0) {
                        reasoning = safeStr(delta, "reasoning");
                    }
                    if (reasoning.length() == 0) {
                        reasoning = safeStr(delta, "thinking");
                    }
                    if (reasoning.length() > 0) {
                        thinkingAccumulated.append(reasoning);
                        notifyThinking(thinkingAccumulated.toString());
                    }
                }

                // Finish_reason check — if present, we're done with this choice.
                String finishReason = choice.optString("finish_reason", "");
                if (finishReason != null && finishReason.length() > 0 && !finishReason.equals("null")) {
                    // Don't break — there might still be content in this
                    // chunk. Just remember we saw it.
                }
            } catch (Exception e) {
                // Ignore malformed chunks
                Log.w(TAG, "parse error: " + e.getMessage());
            }
        }

        try { reader.close(); } catch (Exception ignored) {}
        try { is.close(); } catch (Exception ignored) {}

        if (cancelled) return;

        // v0.2: if we never saw an SSE data line but the connection
        // succeeded, the server probably returned plain JSON despite
        // stream=true. Try parsing the accumulated raw text as a
        // fallback. (We can't re-read the stream — it's consumed.)
        if (!sawAnyData && accumulated.length() == 0) {
            // Best we can do is report empty — the stream produced no
            // parseable SSE events. The user will see "⚠️ 空回复".
            Log.w(TAG, "SSE stream produced no data lines");
        }

        notifyFinish(accumulated.toString(), thinkingAccumulated.toString());
    }

    /** Parse a non-streaming JSON chat completion response. */
    private void parseNonStreamJson(String respBody) {
        if (respBody == null || respBody.length() == 0) return;
        try {
            JSONObject obj = new JSONObject(respBody);
            JSONArray choices = obj.optJSONArray("choices");
            if (choices == null || choices.length() == 0) return;
            JSONObject choice = choices.getJSONObject(0);
            JSONObject message = choice.optJSONObject("message");
            if (message == null) return;

            // v0.3: safeStr 过滤 JSON null → "null" 字符串 bug
            String content = safeStr(message, "content");
            if (content.length() > 0) {
                accumulated.append(content);
                notifyChunk(accumulated.toString());
            }

            String reasoning = safeStr(message, "reasoning_content");
            if (reasoning.length() == 0) {
                reasoning = safeStr(message, "reasoning");
            }
            if (reasoning.length() == 0) {
                reasoning = safeStr(message, "thinking");
            }
            if (reasoning.length() > 0) {
                thinkingAccumulated.append(reasoning);
                notifyThinking(thinkingAccumulated.toString());
            }
        } catch (Exception e) {
            Log.w(TAG, "non-stream parse error: " + e.getMessage());
        }
    }

    private String readStream(InputStream is) {
        if (is == null) return "";
        try {
            BufferedReader r = new BufferedReader(new InputStreamReader(is, "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) {
                sb.append(line).append("\n");
            }
            r.close();
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    private static String truncate(String s, int max) {
        if (s == null) return "";
        return s.length() <= max ? s : s.substring(0, max) + "…";
    }

    /**
     * v0.3: 把底层网络异常翻译成用户能看懂的中文消息。
     * Android 2.3 老设备用户看到 'UnknownHostException: xxx' 会懵，
     * 而且 ⚠️ emoji 在 2.3 显示成方块（无 emoji 字体）。
     * 这里分类常见异常 → 友好中文 + 原始信息（截断）。
     */
    private static String friendlyError(Exception e) {
        if (e == null) return "未知错误";
        String cls = e.getClass().getSimpleName();
        String msg = e.getMessage();
        if (e instanceof java.net.UnknownHostException) {
            return "无法连接服务器：DNS 解析失败（" + truncate(msg, 60) + "）— 请检查网络或 base URL";
        }
        if (e instanceof java.net.SocketTimeoutException) {
            return "连接超时：服务器未响应（" + truncate(msg, 60) + "）";
        }
        if (e instanceof java.net.ConnectException) {
            return "连接被拒绝（" + truncate(msg, 60) + "）— 服务器可能不可达或端口错误";
        }
        if (e instanceof javax.net.ssl.SSLException
            || (msg != null && msg.contains("SSL"))) {
            return "SSL/TLS 握手失败（" + truncate(msg, 60) + "）— 设备可能不支持 TLS 1.2";
        }
        if (e instanceof java.io.IOException) {
            return "网络 IO 错误（" + truncate(msg, 60) + "）";
        }
        return cls + ": " + truncate(msg, 80);
    }

    /**
     * v0.3: 安全读 String 字段。
     * Android org.json 的 optString(key, fallback) 在 key 对应 JSON null 时
     * 返回字符串 "null"（不是 fallback）— 因为 JSON.toString(JSONObject.NULL)
     * 返回 String.valueOf(JSONObject.NULL) = "null"。这导致 SSE delta 里
     * "content": null / "reasoning_content": null 被转成 "null" 字符串
     * append 进累积文本，UI 显示 "nullnullnull…" 和 "💭 null嗯…"。
     *
     * 此 helper 同时处理：key 不存在、JSON null、字符串 "null" 三种情况。
     */
    private static String safeStr(JSONObject obj, String key) {
        if (obj == null) return "";
        if (obj.isNull(key)) return "";  // 显式 JSON null 或 key 不存在
        String s = obj.optString(key, "");
        if (s == null || s.length() == 0 || "null".equals(s)) return "";
        return s;
    }

    // --- Listener notifications (on main thread) ---

    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private void notifyChunk(final String text) {
        mainHandler.post(new Runnable() {
            @Override public void run() {
                if (listener != null) listener.onChunk(text);
            }
        });
    }

    private void notifyThinking(final String text) {
        mainHandler.post(new Runnable() {
            @Override public void run() {
                if (listener != null) listener.onThinking(text);
            }
        });
    }

    private void notifyFinish(final String text, final String thinking) {
        mainHandler.post(new Runnable() {
            @Override public void run() {
                if (listener != null) listener.onFinish(text, thinking);
            }
        });
    }

    private void notifyError(final String msg) {
        mainHandler.post(new Runnable() {
            @Override public void run() {
                if (listener != null) listener.onError(msg);
            }
        });
    }

    /**
     * v0.4: 包装默认 SSLSocketFactory，强制启用 TLS 1.2/1.1/1.0。
     * Android 2.3 默认只启用 TLS 1.0，某些 OEM build 即使 SSLContext.getInstance("TLS")
     * 也不自动启用 TLS 1.2。这个 factory 在每个 socket 创建后强制 setEnabledProtocols。
     * Conscrypt/ProviderInstaller 不支持 Android 2.3（minSdk=21），这是 2.3 的最佳方案。
     */
    private static class TLSSocketFactory extends javax.net.ssl.SSLSocketFactory {
        private final javax.net.ssl.SSLSocketFactory delegate;
        private final String[] protocols = {"TLSv1.2", "TLSv1.1", "TLSv1"};

        TLSSocketFactory(javax.net.ssl.SSLSocketFactory delegate) {
            this.delegate = delegate;
        }

        private java.net.Socket patch(java.net.Socket s) {
            if (s instanceof javax.net.ssl.SSLSocket) {
                javax.net.ssl.SSLSocket ssl = (javax.net.ssl.SSLSocket) s;
                try { ssl.setEnabledProtocols(protocols); }
                catch (IllegalArgumentException e) {
                    // 设备不支持 TLS 1.2 — 保留默认协议
                    Log.w(TAG, "TLS 1.2 not supported on this device");
                }
            }
            return s;
        }

        @Override
        public String[] getDefaultCipherSuites() { return delegate.getDefaultCipherSuites(); }

        @Override
        public String[] getSupportedCipherSuites() { return delegate.getSupportedCipherSuites(); }

        @Override
        public java.net.Socket createSocket(java.net.Socket s, String host, int port, boolean autoClose) throws java.io.IOException {
            return patch(delegate.createSocket(s, host, port, autoClose));
        }

        @Override
        public java.net.Socket createSocket(String host, int port) throws java.io.IOException {
            return patch(delegate.createSocket(host, port));
        }

        @Override
        public java.net.Socket createSocket(String host, int port, java.net.InetAddress localHost, int localPort) throws java.io.IOException {
            return patch(delegate.createSocket(host, port, localHost, localPort));
        }

        @Override
        public java.net.Socket createSocket(java.net.InetAddress host, int port) throws java.io.IOException {
            return patch(delegate.createSocket(host, port));
        }

        @Override
        public java.net.Socket createSocket(java.net.InetAddress address, int port, java.net.InetAddress localAddress, int localPort) throws java.io.IOException {
            return patch(delegate.createSocket(address, port, localAddress, localPort));
        }
    }
}
