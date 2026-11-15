using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Windows.Storage;

namespace AIAnyWhere.Services
{
    /// <summary>
    /// 会话持久化 — 保存/加载/导出/导入对话历史。
    /// 存储到 ApplicationData.Current.LocalFolder 下的 conversations/。
    /// </summary>
    public class ConversationStore
    {
        private static StorageFolder RootFolder()
        {
            return ApplicationData.Current.LocalFolder;
        }

        private static async Task<StorageFolder> GetConvFolder()
        {
            return await RootFolder().CreateFolderAsync("conversations", CreationCollisionOption.OpenIfExists);
        }

        public class StoredMessage
        {
            public string role;
            public string content;
            public string thinking;
        }

        public class StoredConversation
        {
            public string id;
            public string title;
            public long timestamp;
            public List<StoredMessage> messages = new List<StoredMessage>();
        }

        public static async Task<string> SaveConversationAsync(string title, List<StoredMessage> messages)
        {
            var folder = await GetConvFolder();
            string id = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            var conv = new StoredConversation
            {
                id = id,
                title = string.IsNullOrEmpty(title) ? "对话 " + id : title,
                timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                messages = messages
            };
            string json = JsonConvert.SerializeObject(conv);
            string filename = id + ".json";
            var file = await folder.CreateFileAsync(filename, CreationCollisionOption.ReplaceExisting);
            await FileIO.WriteTextAsync(file, json);
            return id;
        }

        public static async Task<List<StoredConversation>> ListConversationsAsync()
        {
            var folder = await GetConvFolder();
            var result = new List<StoredConversation>();
            var files = await folder.GetFilesAsync();
            foreach (var file in files)
            {
                try
                {
                    string json = await FileIO.ReadTextAsync(file);
                    var conv = JsonConvert.DeserializeObject<StoredConversation>(json);
                    if (conv != null) result.Add(conv);
                }
                catch { }
            }
            result.Sort((a, b) => b.timestamp.CompareTo(a.timestamp));
            return result;
        }

        public static async Task<StoredConversation> LoadConversationAsync(string id)
        {
            var folder = await GetConvFolder();
            try
            {
                var file = await folder.GetFileAsync(id + ".json");
                string json = await FileIO.ReadTextAsync(file);
                return JsonConvert.DeserializeObject<StoredConversation>(json);
            }
            catch { return null; }
        }

        public static async Task<bool> DeleteConversationAsync(string id)
        {
            var folder = await GetConvFolder();
            try
            {
                var file = await folder.GetFileAsync(id + ".json");
                await file.DeleteAsync();
                return true;
            }
            catch { return false; }
        }

        public static async Task<bool> ExportConversationAsync(string id, StorageFile target)
        {
            var conv = await LoadConversationAsync(id);
            if (conv == null) return false;
            string json = JsonConvert.SerializeObject(conv, Formatting.Indented);
            await FileIO.WriteTextAsync(target, json);
            return true;
        }

        public static async Task<bool> ImportConversationAsync(StorageFile source)
        {
            try
            {
                string json = await FileIO.ReadTextAsync(source);
                var conv = JsonConvert.DeserializeObject<StoredConversation>(json);
                if (conv == null) return false;
                var folder = await GetConvFolder();
                if (string.IsNullOrEmpty(conv.id))
                    conv.id = DateTime.Now.ToString("yyyyMMdd_HHmmss");
                var file = await folder.CreateFileAsync(conv.id + ".json", CreationCollisionOption.ReplaceExisting);
                await FileIO.WriteTextAsync(file, JsonConvert.SerializeObject(conv));
                return true;
            }
            catch { return false; }
        }
    }
}
