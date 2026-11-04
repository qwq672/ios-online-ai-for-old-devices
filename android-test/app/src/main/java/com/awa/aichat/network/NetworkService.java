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
 * Usage:
 *   NetworkService svc = new NetworkService();
 *   svc.setListener(new NetworkService.Listener() { ... });
 *   svc.streamChat(baseURL, apiKey, model, messages, systemPrompt, temperature);
 */
public class NetworkService {

    private static final String TAG = "NetworkService";
    private static final int TIMEOUT = 120000; // 2 min

    public interface Listener {
        void onChunk(String fullText);
        void onThinking(String thinkingText);
        void onFinish(String fullText, String thinking);
        void onError(String message);
    }

    private Listener listener;
    private volatile boolean cancelled = false;
    private HttpURLConnection connection;
    private Thread streamThread;

    // Accumulated text + thinking
    private final StringBuilder accumulated = new StringBuilder();
    private final StringBuilder thinkingAccumulated = new StringBuilder();

    public void setListener(Listener l) { this.listener = l; }

    public void streamChat(final String baseURL, final String apiKey,
                           final String model, final List<Message> messages,
                           final String systemPrompt, final float temperature) {
        cancelled = false;
        accumulated.setLength(0);
        thinkingAccumulated.setLength(0);

        streamThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    doStream(baseURL, apiKey, model, messages, systemPrompt, temperature);
                } catch (Exception e) {
                    Log.e(TAG, "stream error", e);
                    notifyError(e.getMessage());
                }
            }
        }, "AIChat-Stream");
        streamThread.start();
    }

    public void cancel() {
        cancelled = true;
        if (connection != null) {
            try { connection.disconnect(); } catch (Exception ignored) {}
        }
    }

    private void doStream(String baseURL, String apiKey, String model,
                          List<Message> messages, String systemPrompt,
                          float temperature) throws Exception {

        // Build endpoint URL
        String endpoint = baseURL;
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
            msgsArr.put(new JSONObject().put("role", m.roleName()).put("content", m.content));
        }

        // Build request body
        JSONObject body = new JSONObject();
        body.put("model", model);
        body.put("messages", msgsArr);
        body.put("stream", true);
        body.put("temperature", temperature);

        String bodyStr = body.toString();

        // Create connection
        URL url = new URL(endpoint);
        connection = (HttpURLConnection) url.openConnection();
        connection.setRequestMethod("POST");
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Accept", "text/event-stream");
        if (apiKey != null && apiKey.length() > 0) {
            connection.setRequestProperty("Authorization", "Bearer " + apiKey);
        }
        connection.setConnectTimeout(TIMEOUT);
        connection.setReadTimeout(TIMEOUT);
        connection.setDoOutput(true);

        // Write body
        OutputStream os = connection.getOutputStream();
        os.write(bodyStr.getBytes("UTF-8"));
        os.flush();
        os.close();

        int code = connection.getResponseCode();
        if (code < 200 || code >= 300) {
            String errBody = readStream(connection.getErrorStream());
            notifyError("HTTP " + code + ": " + errBody);
            return;
        }

        // Read SSE stream
        InputStream is = connection.getInputStream();
        BufferedReader reader = new BufferedReader(new InputStreamReader(is, "UTF-8"));
        String line;

        while (!cancelled && (line = reader.readLine()) != null) {
            line = line.trim();
            if (line.length() == 0) continue;
            if (!line.startsWith("data:")) continue;

            String payload = line.substring(5).trim();
            if (payload.equals("[DONE]")) break;
            if (payload.length() == 0) continue;

            try {
                JSONObject obj = new JSONObject(payload);
                JSONArray choices = obj.optJSONArray("choices");
                if (choices == null || choices.length() == 0) continue;

                JSONObject choice = choices.getJSONObject(0);
                JSONObject delta = choice.optJSONObject("delta");
                if (delta == null) continue;

                // Content
                String content = delta.optString("content", "");
                if (content.length() > 0) {
                    accumulated.append(content);
                    notifyChunk(accumulated.toString());
                }

                // Reasoning / thinking
                String reasoning = delta.optString("reasoning_content", "");
                if (reasoning.length() == 0) reasoning = delta.optString("reasoning", "");
                if (reasoning.length() == 0) reasoning = delta.optString("thinking", "");
                if (reasoning.length() > 0) {
                    thinkingAccumulated.append(reasoning);
                    notifyThinking(thinkingAccumulated.toString());
                }
            } catch (Exception e) {
                // Ignore malformed chunks
                Log.w(TAG, "parse error: " + e.getMessage());
            }
        }

        reader.close();
        is.close();

        if (cancelled) return;

        // If no SSE data was parsed, try non-stream JSON
        if (accumulated.length() == 0) {
            // Re-read the body (already consumed by reader, so this won't work)
            // Just report empty
            notifyFinish(accumulated.toString(), thinkingAccumulated.toString());
        } else {
            notifyFinish(accumulated.toString(), thinkingAccumulated.toString());
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
}
