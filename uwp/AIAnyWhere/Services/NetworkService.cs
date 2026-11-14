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

        public NetworkService()
        {
            client = new HttpClient();
            client.Timeout = TimeSpan.FromSeconds(120);
        }

        public async Task StreamChatAsync(string baseURL, string apiKey, string model, List<ChatMessage> messages)
        {
            cts = new CancellationTokenSource();
            try
            {
                string endpoint = baseURL.TrimEnd('/');
                if (!endpoint.EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase))
                    endpoint += "/chat/completions";

                var payload = new List<object>();
                foreach (var message in messages)
                {
                    payload.Add(new { role = message.Role, content = message.Content });
                }
                var body = new
                {
                    model = model,
                    messages = payload,
                    stream = true
                };
                string json = JsonConvert.SerializeObject(body);

                var req = new HttpRequestMessage(HttpMethod.Post, endpoint);
                req.Content = new StringContent(json, Encoding.UTF8, "application/json");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
                req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
                req.Headers.TryAddWithoutValidation("User-Agent", "AIAnyWhere/0.1 UWP");

                var resp = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
                if (!resp.IsSuccessStatusCode)
                {
                    string errBody = await resp.Content.ReadAsStringAsync();
                    Listener?.OnError("HTTP " + resp.StatusCode + ": " + Truncate(errBody, 200));
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
                            string data = line.Substring(6);
                            if (data == "[DONE]") break;

                            try
                            {
                                var chunk = JObject.Parse(data);
                                var delta = chunk["choices"]?[0]?["delta"];
                                if (delta != null)
                                {
                                    var content = delta["content"];
                                    if (content != null && content.Type != JTokenType.Null)
                                    {
                                        accumulated.Append(content.ToString());
                                        Listener?.OnChunk(accumulated.ToString());
                                    }
                                }
                            }
                            catch { }
                        }
                    }
                }
                Listener?.OnFinish();
            }
            catch (OperationCanceledException)
            {
                Listener?.OnFinish();
            }
            catch (Exception e)
            {
                Listener?.OnError(e.Message ?? "未知错误");
            }
        }

        public void Cancel()
        {
            cts?.Cancel();
        }

        private static string Truncate(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Length <= max ? s : s.Substring(0, max) + "...";
        }
    }
}
