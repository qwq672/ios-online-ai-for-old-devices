using System;
using System.Collections.Generic;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Windows.Storage;

namespace AIAnyWhere.Services
{
    /// <summary>
    /// 设置存储 — 集中管理 LocalSettings 读写，提供默认值。
    /// </summary>
    public static class SettingsStore
    {
        public static string ApiKey => Get("api_key", "");
        public static string BaseUrl => Get("base_url", "https://api.openai.com/v1");
        public static string Model => Get("model", "gpt-3.5-turbo");
        public static string SystemPrompt => Get("system_prompt", "You are a helpful assistant.");
        public static bool Stream => GetBool("stream", true);
        public static bool DarkTheme => GetBool("dark_theme", false);
        public static int MaxTokens => GetInt("max_tokens", 0);
        public static double Temperature => GetDouble("temperature", 0.7);
        public static string Provider => Get("provider", "openai");
        public static bool ShowThinking => GetBool("show_thinking", true);

        public static void Set(string key, string value)
        {
            ApplicationData.Current.LocalSettings.Values[key] = value;
        }

        public static void SetBool(string key, bool value)
        {
            ApplicationData.Current.LocalSettings.Values[key] = value;
        }

        public static void SetInt(string key, int value)
        {
            ApplicationData.Current.LocalSettings.Values[key] = value;
        }

        public static void SetDouble(string key, double value)
        {
            ApplicationData.Current.LocalSettings.Values[key] = value;
        }

        public static string Get(string key, string def)
        {
            var v = ApplicationData.Current.LocalSettings.Values[key] as string;
            return string.IsNullOrEmpty(v) ? def : v;
        }

        public static bool GetBool(string key, bool def)
        {
            var v = ApplicationData.Current.LocalSettings.Values[key];
            if (v is bool b) return b;
            return def;
        }

        public static int GetInt(string key, int def)
        {
            var v = ApplicationData.Current.LocalSettings.Values[key];
            if (v is int i) return i;
            if (v is string s && int.TryParse(s, out int parsed)) return parsed;
            return def;
        }

        public static double GetDouble(string key, double def)
        {
            var v = ApplicationData.Current.LocalSettings.Values[key];
            if (v is double d) return d;
            if (v is int i) return (double)i;
            if (v is string s && double.TryParse(s, out double parsed)) return parsed;
            return def;
        }

        // 预设供应商
        public class Provider
        {
            public string Id;
            public string Name;
            public string BaseUrl;
            public string DefaultModel;
        }

        public static readonly List<Provider> Providers = new List<Provider>
        {
            new Provider { Id = "openai", Name = "OpenAI", BaseUrl = "https://api.openai.com/v1", DefaultModel = "gpt-3.5-turbo" },
            new Provider { Id = "glm", Name = "智谱 GLM", BaseUrl = "https://open.bigmodel.cn/api/paas/v4", DefaultModel = "glm-4-flash" },
            new Provider { Id = "deepseek", Name = "DeepSeek", BaseUrl = "https://api.deepseek.com/v1", DefaultModel = "deepseek-chat" },
            new Provider { Id = "moonshot", Name = "月之暗面 Kimi", BaseUrl = "https://api.moonshot.cn/v1", DefaultModel = "moonshot-v1-8k" },
            new Provider { Id = "qwen", Name = "通义千问", BaseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1", DefaultModel = "qwen-turbo" },
            new Provider { Id = "doubao", Name = "豆包", BaseUrl = "https://ark.cn-beijing.volces.com/api/v3", DefaultModel = "doubao-lite-4k" },
            new Provider { Id = "custom", Name = "自定义", BaseUrl = "", DefaultModel = "" }
        };
    }
}
