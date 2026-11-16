using System;
using System.Collections.ObjectModel;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Windows.UI;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Input;
using Windows.UI.Xaml.Media;
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
            // v261116-12: 默认选中聊天项（NavigationView）
            // 在 Loaded 事件后选中，避免初始化期触发 SelectionChanged
            Loaded += (s, e) =>
            {
                if (NavView.SelectedItem == null)
                {
                    foreach (var item in NavView.MenuItems)
                    {
                        if (item is Microsoft.UI.Xaml.Controls.NavigationViewItem nvi && (string)nvi.Tag == "chat")
                        {
                            NavView.SelectedItem = nvi;
                            break;
                        }
                    }
                }
            };
        }

        // v261116-12: NavigationView SelectionChanged
        private void NavView_SelectionChanged(Microsoft.UI.Xaml.Controls.NavigationView sender,
                                              Microsoft.UI.Xaml.Controls.NavigationViewSelectionChangedEventArgs args)
        {
            if (args.SelectedItem == null) return;
            var nvi = args.SelectedItem as Microsoft.UI.Xaml.Controls.NavigationViewItem;
            if (nvi == null) return;
            string tag = nvi.Tag as string;
            switch (tag)
            {
                case "chat":
                    MessageList.Visibility = Visibility.Visible;
                    HistoryPanel.Visibility = Visibility.Collapsed;
                    break;
                case "history":
                    MessageList.Visibility = Visibility.Collapsed;
                    HistoryPanel.Visibility = Visibility.Visible;
                    LoadHistoryList();
                    break;
                case "settings":
                    Frame.Navigate(typeof(SettingsPage));
                    NavView.SelectedItem = null;
                    break;
            }
        }

        // === 历史对话列表 ===
        private async void LoadHistoryList()
        {
            HistoryList.Items.Clear();
            var convs = await ConversationStore.ListConversationsAsync();
            foreach (var c in convs)
            {
                var dt = DateTimeOffset.FromUnixTimeSeconds(c.timestamp).LocalDateTime;
                HistoryList.Items.Add(new
                {
                    title = c.title,
                    subtitle = dt.ToString("yyyy-MM-dd HH:mm") + "  · " + c.messages.Count + " 条",
                    id = c.id
                });
            }
            if (HistoryList.Items.Count == 0)
            {
                HistoryList.Items.Add(new { title = "暂无历史对话", subtitle = "发送消息后会自动保存", id = "" });
            }
        }

        private async void HistoryList_ItemClick(object sender, ItemClickEventArgs e)
        {
            dynamic item = e.ClickedItem;
            if (item == null) return;
            string id = item.id;
            if (string.IsNullOrEmpty(id)) return;
            await LoadConversationAsync(id);
            // 切换回聊天视图
            foreach (var nvi in NavView.MenuItems)
            {
                if (nvi is Microsoft.UI.Xaml.Controls.NavigationViewItem navItem && (string)navItem.Tag == "chat")
                {
                    NavView.SelectedItem = navItem;
                    break;
                }
            }
        }

        private void SendBtn_Click(object sender, RoutedEventArgs e) { DoSend(); }

        private void InputBox_KeyDown(object sender, Windows.UI.Xaml.Input.KeyRoutedEventArgs e)
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                bool shift = Window.Current.CoreWindow.GetKeyState(Windows.System.VirtualKey.Shift)
                    .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                if (!shift)
                {
                    e.Handled = true;
                    DoSend();
                }
            }
        }

        private void DoSend()
        {
            if (isStreaming)
            {
                networkService.Cancel();
                return;
            }
            string text = InputBox.Text.Trim();
            if (string.IsNullOrEmpty(text)) return;

            var userMsg = new ChatMessage { Role = "user", Content = text, IsUser = true };
            messages.Add(userMsg);

            var aiMsg = new ChatMessage { Role = "assistant", Content = "正在思考..." };
            messages.Add(aiMsg);

            InputBox.Text = "";
            isStreaming = true;
            SendBtn.Content = "停止";

            string apiKey = SettingsStore.ApiKey;
            string baseURL = SettingsStore.BaseUrl;
            string model = SettingsStore.Model;

            if (string.IsNullOrEmpty(apiKey))
            {
                OnError("未设置 API Key，请到设置页填写");
                return;
            }

            var apiMsgs = new List<ChatMessage>(messages);
            apiMsgs.RemoveAt(apiMsgs.Count - 1);

            string systemPrompt = SettingsStore.SystemPrompt;
            if (!string.IsNullOrWhiteSpace(systemPrompt))
            {
                apiMsgs.Insert(0, new ChatMessage { Role = "system", Content = systemPrompt });
            }

            int maxTokens = SettingsStore.MaxTokens;
            double temp = SettingsStore.Temperature;
            _ = networkService.StreamChatAsync(baseURL, apiKey, model, apiMsgs, maxTokens, temp);
            ScrollToBottom();
        }

        // === MenuFlyout 事件 ===
        private void CopyMessage_Click(object sender, RoutedEventArgs e)
        {
            if (sender is MenuFlyoutItem item && item.Tag is ChatMessage msg)
            {
                var content = msg.Content ?? "";
                var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
                package.SetText(content);
                Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
                ShowToast("已复制到剪贴板");
            }
        }

        private void RegenerateMessage_Click(object sender, RoutedEventArgs e)
        {
            if (isStreaming)
            {
                ShowToast("正在生成中，请先停止");
                return;
            }
            if (!(sender is MenuFlyoutItem item) || !(item.Tag is ChatMessage msg)) return;
            // 找到这条 AI 消息，往前找最近一条 user 消息作为新请求
            int idx = messages.IndexOf(msg);
            if (idx < 0) return;
            // 删除当前 AI 消息及之后所有消息
            while (messages.Count > idx)
            {
                messages.RemoveAt(idx);
            }
            // 找上一条 user 消息
            string lastUserText = "";
            for (int i = messages.Count - 1; i >= 0; i--)
            {
                if (messages[i].IsUser)
                {
                    lastUserText = messages[i].Content;
                    // 删除这条 user 消息（重新发送）
                    messages.RemoveAt(i);
                    break;
                }
            }
            if (string.IsNullOrEmpty(lastUserText))
            {
                ShowToast("找不到上一条用户消息");
                return;
            }
            // 重新发送
            InputBox.Text = lastUserText;
            DoSend();
        }

        private void DeleteMessage_Click(object sender, RoutedEventArgs e)
        {
            if (sender is MenuFlyoutItem item && item.Tag is ChatMessage msg)
            {
                messages.Remove(msg);
                ShowToast("已删除");
            }
        }

        private void ShowToast(string text)
        {
            // 简单状态提示 — 用 StatusBar 风格（这里用 InAppNotification 替代不实际，
            // 简化为 InputBox placeholder 短暂显示）
            var originalPlaceholder = InputBox.PlaceholderText;
            InputBox.PlaceholderText = text;
            Task.Delay(2000).ContinueWith(t =>
            {
                Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
                {
                    if (InputBox.PlaceholderText == text)
                        InputBox.PlaceholderText = originalPlaceholder;
                });
            });
        }

        private void ThinkingToggle_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button btn && btn.DataContext is ChatMessage msg)
            {
                msg.ThinkingExpanded = !msg.ThinkingExpanded;
            }
        }

        private void ScrollToBottom()
        {
            if (MessageList.Items.Count > 0)
            {
                var lastItem = MessageList.Items[MessageList.Items.Count - 1];
                MessageList.ScrollIntoView(lastItem);
            }
        }

        // === 网络回调 ===
        public async void OnChunk(string fullText)
        {
            await Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
            {
                if (messages.Count > 0)
                {
                    var last = messages[messages.Count - 1];
                    last.Content = fullText;
                }
                ScrollToBottom();
            });
        }

        public async void OnThinking(string thinking)
        {
            await Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () =>
            {
                if (messages.Count > 0)
                {
                    var last = messages[messages.Count - 1];
                    last.Thinking = thinking;
                }
            });
        }

        public async void OnFinish()
        {
            await Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, async () =>
            {
                isStreaming = false;
                SendBtn.Content = "发送";

                if (messages.Count >= 2)
                {
                    var stored = new List<ConversationStore.StoredMessage>();
                    foreach (var m in messages)
                    {
                        stored.Add(new ConversationStore.StoredMessage
                        {
                            role = m.Role,
                            content = m.Content,
                            thinking = m.Thinking
                        });
                    }
                    string title = messages[0].Content;
                    if (title.Length > 30) title = title.Substring(0, 30);
                    try
                    {
                        await ConversationStore.SaveConversationAsync(title, stored);
                    }
                    catch { }
                }
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
                    var last = messages[messages.Count - 1];
                    last.IsError = true;
                    last.Content = "[错误] " + message;
                }
            });
        }

        private async Task LoadConversationAsync(string id)
        {
            var conv = await ConversationStore.LoadConversationAsync(id);
            if (conv == null) return;
            messages.Clear();
            foreach (var m in conv.messages)
            {
                messages.Add(new ChatMessage
                {
                    Role = m.role,
                    Content = m.content ?? "",
                    Thinking = m.thinking ?? "",
                    IsUser = (m.role == "user"),
                });
            }
            ScrollToBottom();
        }
    }

    public class ChatMessage : INotifyPropertyChanged
    {
        private string role = "";
        private string content = "";
        private string thinking = "";
        private bool isUser;
        private bool isError;
        private bool thinkingExpanded;

        public bool IsUser
        {
            get { return isUser; }
            set
            {
                isUser = value;
                OnPropertyChanged();
                OnPropertyChanged("BubbleBackground");
                OnPropertyChanged("ContentForeground");
                OnPropertyChanged("LeftSpacerWidth");
                OnPropertyChanged("RightSpacerWidth");
                OnPropertyChanged("RoleDisplay");
            }
        }

        public bool IsError
        {
            get { return isError; }
            set
            {
                isError = value;
                OnPropertyChanged();
                OnPropertyChanged("BubbleBackground");
                OnPropertyChanged("ContentForeground");
                OnPropertyChanged("RoleDisplay");
            }
        }

        public string Role
        {
            get { return role; }
            set { role = value; OnPropertyChanged(); OnPropertyChanged("RoleDisplay"); }
        }

        public string Content
        {
            get { return content; }
            set { content = value; OnPropertyChanged(); }
        }

        public string Thinking
        {
            get { return thinking; }
            set
            {
                thinking = value;
                OnPropertyChanged();
                OnPropertyChanged("ThinkingVisibility");
                OnPropertyChanged("ThinkingToggleText");
            }
        }

        public bool ThinkingExpanded
        {
            get { return thinkingExpanded; }
            set
            {
                thinkingExpanded = value;
                OnPropertyChanged();
                OnPropertyChanged("ThinkingToggleText");
                OnPropertyChanged("ThinkingContentVisibility");
            }
        }

        // === Spacer 宽度 ===
        public string LeftSpacerWidth => isUser ? "*" : "0";
        public string RightSpacerWidth => isUser ? "0" : "*";
        public string BubbleWidth => "*";

        // v261116-10: UWP 原生颜色 — 用系统主题资源，不用硬编码 RGB
        // 用户消息：SystemAccentColor（系统强调色，深色/浅色自适应）
        // AI 消息：SystemControlBackgroundAltMediumBrush（系统次级背景）
        // 错误消息：SystemControlErrorBackgroundBrush
        // v261116-12: 缓存 accent 色（避免每次读 BubbleBackground 都查 UISettings）
        private static Brush _cachedAccentBrush;
        private static Brush _cachedErrorBgBrush;
        private static Brush _cachedErrorFgBrush;
        private static Brush _cachedAltMediumBrush;
        private static Brush _cachedBaseHighBrush;
        private static Brush _cachedWhiteBrush;
        private static bool _brushesCached = false;

        private static void CacheBrushes()
        {
            if (_brushesCached) return;
            try
            {
                // v261116-12: 用 UISettings 获取系统 accent 色 — 最稳定可靠
                var uiSettings = new Windows.UI.ViewManagement.UISettings();
                Windows.UI.Color accentColor = uiSettings.GetColorValue(Windows.UI.ViewManagement.UIColorType.Accent);
                _cachedAccentBrush = new SolidColorBrush(accentColor);

                // v261116-12c: UIColorType 没有 Error（14393/15063 都没有）
                // 用硬编码红色作为错误色（深色/浅色模式都用同一红）
                Windows.UI.Color errorColor = Windows.UI.Color.FromArgb(255, 196, 30, 30);
                _cachedErrorBgBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x33, errorColor.R, errorColor.G, errorColor.B));
                _cachedErrorFgBrush = new SolidColorBrush(errorColor);

                _cachedWhiteBrush = new SolidColorBrush(Colors.White);

                // 系统 alt/base 资源 — 尝试从当前 Page 拿（fallback 到 Application）
                if (Application.Current.Resources.ContainsKey("SystemControlBackgroundAltMediumBrush"))
                    _cachedAltMediumBrush = (Brush)Application.Current.Resources["SystemControlBackgroundAltMediumBrush"];
                if (Application.Current.Resources.ContainsKey("SystemControlForegroundBaseHighBrush"))
                    _cachedBaseHighBrush = (Brush)Application.Current.Resources["SystemControlForegroundBaseHighBrush"];

                // Fallback — 如果系统资源不存在
                if (_cachedAltMediumBrush == null)
                {
                    bool dark = Windows.UI.Xaml.Application.Current.RequestedTheme == ApplicationTheme.Dark;
                    _cachedAltMediumBrush = new SolidColorBrush(dark ?
                        Windows.UI.Color.FromArgb(255, 38, 38, 42) : Windows.UI.Color.FromArgb(255, 248, 248, 248));
                }
                if (_cachedBaseHighBrush == null)
                {
                    bool dark = Windows.UI.Xaml.Application.Current.RequestedTheme == ApplicationTheme.Dark;
                    _cachedBaseHighBrush = new SolidColorBrush(dark ? Colors.White : Colors.Black);
                }
            }
            catch (Exception ex)
            {
                // 兜底 — 至少不为 null
                _cachedAccentBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0, 120, 215));
                _cachedErrorBgBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 252, 220, 220));
                _cachedErrorFgBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 180, 30, 30));
                _cachedAltMediumBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 248, 248, 248));
                _cachedBaseHighBrush = new SolidColorBrush(Colors.Black);
                _cachedWhiteBrush = new SolidColorBrush(Colors.White);
            }
            _brushesCached = true;
        }

        public Brush BubbleBackground
        {
            get
            {
                CacheBrushes();
                if (isError) return _cachedErrorBgBrush;
                if (isUser) return _cachedAccentBrush;
                return _cachedAltMediumBrush;
            }
        }

        public Brush ContentForeground
        {
            get
            {
                CacheBrushes();
                if (isError) return _cachedErrorFgBrush;
                if (isUser) return _cachedWhiteBrush;
                return _cachedBaseHighBrush;
            }
        }

        public Visibility ThinkingVisibility => string.IsNullOrEmpty(thinking) ? Visibility.Collapsed : Visibility.Visible;
        public Visibility ThinkingContentVisibility => thinkingExpanded ? Visibility.Visible : Visibility.Collapsed;

        public string ThinkingToggleText
        {
            get
            {
                if (string.IsNullOrEmpty(thinking)) return "";
                return thinkingExpanded ? "思考 · 点击收起" : "思考 · 点击展开";
            }
        }

        public string RoleDisplay
        {
            get
            {
                if (isError) return "错误";
                if (isUser) return "我";
                if (role == "system") return "系统";
                return "AI";
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }

    public class BoolToVisibilityConverter : Windows.UI.Xaml.Data.IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, string language)
        {
            if (value is bool b) return b ? Visibility.Visible : Visibility.Collapsed;
            if (value is Visibility v) return v;
            return Visibility.Collapsed;
        }
        public object ConvertBack(object value, Type targetType, object parameter, string language)
        {
            throw new NotImplementedException();
        }
    }

    public class GridLengthStarConverter : Windows.UI.Xaml.Data.IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, string language)
        {
            string s = value as string;
            if (string.IsNullOrEmpty(s)) return new GridLength(1, GridUnitType.Star);
            if (s == "*") return new GridLength(1, GridUnitType.Star);
            if (s == "0") return new GridLength(0);
            double d;
            if (double.TryParse(s, out d)) return new GridLength(d);
            return new GridLength(1, GridUnitType.Star);
        }
        public object ConvertBack(object value, Type targetType, object parameter, string language)
        {
            throw new NotImplementedException();
        }
    }

    public class NetworkListener
    {
        private MainPage page;
        public NetworkListener(MainPage p) { page = p; }
        public void OnChunk(string fullText) => page.OnChunk(fullText);
        public void OnThinking(string thinking) => page.OnThinking(thinking);
        public void OnFinish() => page.OnFinish();
        public void OnError(string msg) => page.OnError(msg);
    }
}
