using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace AIAnyWhere.Services
{
    public class NetworkService
    {
        public NetworkListener Listener { get; set; }
        private CancellationTokenSource cts;
        private HttpClient client;
        private StringBuilder thinkingAccumulated = new StringBuilder();

        public NetworkService()
        {
            client = new HttpClient();
            client.Timeout = TimeSpan.FromSeconds(120);
        }

        public async Task StreamChatAsync(string baseURL, string apiKey, string model,
            List<ChatMessage> messages, int maxTokens = 0, double temperature = 0.7)
        {
            cts = new CancellationTokenSource();
            thinkingAccumulated.Clear();

            try
            {
                string endpoint = baseURL.TrimEnd('/');
                if (!endpoint.EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase))
                    endpoint += "/chat/completions";

                var payload = new List<object>();
                foreach (var message in messages)
                {
                    if (!string.IsNullOrEmpty(message.Thinking) && message.Role == "assistant")
                    {
                        payload.Add(new { role = message.Role, content = message.Content, thinking = message.Thinking });
                    }
                    else
                    {
                        payload.Add(new { role = message.Role, content = message.Content });
                    }
                }

                var body = new Dictionary<string, object>
                {
                    { "model", model },
                    { "messages", payload },
                    { "stream", true },
                    { "temperature", temperature }
                };
                if (maxTokens > 0) body["max_tokens"] = maxTokens;

                string json = JsonConvert.SerializeObject(body);

                var req = new HttpRequestMessage(HttpMethod.Post, endpoint);
                req.Content = new StringContent(json, Encoding.UTF8, "application/json");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
                req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
                req.Headers.TryAddWithoutValidation("User-Agent", "AIAnyWhere/0.2 UWP");

                var resp = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
                if (!resp.IsSuccessStatusCode)
                {
                    string errBody = "";
                    try { errBody = await resp.Content.ReadAsStringAsync(); } catch { }
                    Listener?.OnError(CategorizeHttpError((int)resp.StatusCode, errBody));
                    return;
                }

                using (var stream = await resp.Content.ReadAsStreamAsync())
                using (var reader = new System.IO.StreamReader(stream))
                {
                    StringBuilder accumulated = new StringBuilder();
                    string line;
                    while ((line = await reader.ReadLineAsync()) != null)
                    {
                        if (cts.Token.IsCancellationRequested) return;

                        if (line.StartsWith("data: "))
                        {
                            string data = line.Substring(6).Trim();
                            if (data == "[DONE]") break;
                            if (data.Length == 0) continue;

                            try
                            {
                                var chunk = JObject.Parse(data);
                                var choices = chunk["choices"] as JArray;
                                if (choices == null || choices.Count == 0) continue;
                                var delta = choices[0]["delta"];
                                if (delta != null)
                                {
                                    var content = delta["content"];
                                    if (content != null && content.Type != JTokenType.Null)
                                    {
                                        string contentStr = content.ToString();
                                        accumulated.Append(contentStr);
                                        Listener?.OnChunk(accumulated.ToString());
                                    }
                                    // reasoning_content / thinking
                                    var reasoning = delta["reasoning_content"];
                                    if (reasoning == null || reasoning.Type == JTokenType.Null)
                                        reasoning = delta["reasoning"];
                                    if (reasoning == null || reasoning.Type == JTokenType.Null)
                                        reasoning = delta["thinking"];
                                    if (reasoning != null && reasoning.Type != JTokenType.Null)
                                    {
                                        thinkingAccumulated.Append(reasoning.ToString());
                                        Listener?.OnThinking(thinkingAccumulated.ToString());
                                    }
                                }
                            }
                            catch { /* 部分行可能不完整，忽略 */ }
                        }
                    }
                }
                Listener?.OnFinish();
            }
            catch (OperationCanceledException)
            {
                Listener?.OnFinish();
            }
            catch (HttpRequestException e)
            {
                Listener?.OnError("网络错误: " + (e.Message ?? "未知"));
            }
            catch (Exception e)
            {
                string msg = e.Message ?? "未知错误";
                if (msg.Contains("SSL") || msg.Contains("TLS") || msg.Contains("certificate"))
                    Listener?.OnError("TLS 证书错误: " + msg);
                else
                    Listener?.OnError(msg);
            }
        }

        public void Cancel()
        {
            try { cts?.Cancel(); } catch { }
        }

        private static string CategorizeHttpError(int code, string body)
        {
            string b = (body ?? "").ToLower();
            if (code == 401 || code == 403)
                return "认证失败 (HTTP " + code + "): API Key 无效或权限不足";
            if (code == 404)
                return "端点不存在 (HTTP 404): 检查 Base URL 是否正确";
            if (code == 429)
                return "请求过多 (HTTP 429): 等待几秒后重试";
            if (code == 400)
            {
                if (b.Contains("model")) return "模型无效 (HTTP 400): 检查模型名是否正确";
                return "请求格式错误 (HTTP 400): " + Truncate(body, 200);
            }
            if (code >= 500)
                return "服务器错误 (HTTP " + code + "): " + Truncate(body, 200);
            return "HTTP " + code + ": " + Truncate(body, 200);
        }

        private static string Truncate(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Length <= max ? s : s.Substring(0, max) + "...";
        }
    }
}
