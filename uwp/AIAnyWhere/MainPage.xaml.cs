using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using AIAnyWhere.Services;

namespace AIAnyWhere
{
    public sealed partial class MainPage : Page
    {
        private ObservableCollection<ChatMessage> messages = new ObservableCollection<ChatMessage>();
        private NetworkService networkService;
        private bool isStreaming = false;

        public MainPage()
        {
            InitializeComponent();
            MessageList.ItemsSource = messages;
            networkService = new NetworkService();
            networkService.Listener = new NetworkListener(this);
        }

        private void SendBtn_Click(object sender, RoutedEventArgs e)
        {
            if (isStreaming)
            {
                networkService.Cancel();
                return;
            }
            string text = InputBox.Text.Trim();
            if (string.IsNullOrEmpty(text)) return;

            // 加用户消息
            messages.Add(new ChatMessage { Role = "user", Content = text });
            // 加 AI 占位
            messages.Add(new ChatMessage { Role = "assistant", Content = "..." });

            InputBox.Text = "";
            isStreaming = true;
            SendBtn.Content = "停止";

            // 读设置
            var settings = Windows.Storage.ApplicationData.Current.LocalSettings;
            string apiKey = settings.Values["api_key"] as string ?? "";
            string baseURL = settings.Values["base_url"] as string ?? "https://api.openai.com/v1";
            string model = settings.Values["model"] as string ?? "gpt-3.5-turbo";

            // 构造消息列表
            var apiMsgs = new System.Collections.Generic.List<ChatMessage>(messages);
            apiMsgs.RemoveAt(apiMsgs.Count - 1); // 移除 AI 占位

            string systemPrompt = settings.Values["system_prompt"] as string;
            if (!string.IsNullOrWhiteSpace(systemPrompt))
            {
                apiMsgs.Insert(0, new ChatMessage { Role = "system", Content = systemPrompt });
            }

            _ = networkService.StreamChatAsync(baseURL, apiKey, model, apiMsgs);
        }

        private void SettingsBtn_Click(object sender, RoutedEventArgs e)
        {
            Frame.Navigate(typeof(SettingsPage));
        }

        // UI 线程更新
        public async void OnChunk(string fullText)
        {
            await Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
            {
                if (messages.Count > 0)
                {
                    messages[messages.Count - 1].Content = fullText;
                }
            });
        }

        public async void OnFinish()
        {
            await Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
            {
                isStreaming = false;
                SendBtn.Content = "发送";
            });
        }

        public async void OnError(string message)
        {
            await Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
            {
                isStreaming = false;
                SendBtn.Content = "发送";
                if (messages.Count > 0)
                {
                    messages[messages.Count - 1].Content = "[错误] " + message;
                }
            });
        }
    }

    public class ChatMessage : INotifyPropertyChanged
    {
        private string role = "";
        private string content = "";

        public string Role
        {
            get { return role; }
            set
            {
                if (role == value) return;
                role = value;
                OnPropertyChanged();
            }
        }

        public string Content
        {
            get { return content; }
            set
            {
                if (content == value) return;
                content = value;
                OnPropertyChanged();
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;

        private void OnPropertyChanged([CallerMemberName] string propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }

    public class NetworkListener
    {
        private MainPage page;
        public NetworkListener(MainPage p) { page = p; }
        public void OnChunk(string fullText) => page.OnChunk(fullText);
        public void OnFinish() => page.OnFinish();
        public void OnError(string msg) => page.OnError(msg);
    }
}
