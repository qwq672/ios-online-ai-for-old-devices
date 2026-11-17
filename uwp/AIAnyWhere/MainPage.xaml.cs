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
            try
            {
                InitializeComponent();
                MessageList.ItemsSource = messages;
                networkService = new NetworkService();
                networkService.Listener = new NetworkListener(this);
                // v261116-15: 用 ListView 填充侧边栏菜单（左侧蓝色竖条选中样式）
                PopulateNavMenus();
                Window.Current.SizeChanged += OnWindowSizeChanged;
                OnWindowSizeChanged(null, null);
                // 默认选中聊天
                NavMenuList.SelectedIndex = 0;
            }
            catch (Exception ex)
            {
                // 启动崩溃 — 写日志
                try
                {
                    var folder = Windows.Storage.ApplicationData.Current.LocalFolder;
                    var file = folder.CreateFileAsync("mainpage_init.log",
                        Windows.Storage.CreationCollisionOption.ReplaceExisting).AsTask().Result;
                    Windows.Storage.FileIO.WriteTextAsync(file,
                        $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] MainPage init: {ex}").AsTask().Wait();
                }
                catch { }
                throw;
            }
        }

        // v261116-15: 填充侧边栏菜单数据
        private void PopulateNavMenus()
        {
            NavMenuList.Items.Clear();
            NavMenuList.Items.Add(new NavItem { Tag = "chat", Icon = "\uE8BD", Title = "聊天" });
            NavMenuList.Items.Add(new NavItem { Tag = "history", Icon = "\uE823", Title = "历史" });

            NavFooterList.Items.Clear();
            NavFooterList.Items.Add(new NavItem { Tag = "settings", Icon = "\uE713", Title = "设置" });
        }

        // v261116-15: 菜单项数据类
        public class NavItem
        {
            public string Tag { get; set; }
            public string Icon { get; set; }
            public string Title { get; set; }
        }

        // v261116-16: 选中状态变化时，显示/隐藏左侧蓝色竖条
        // 通过 ContainerContentChanging 找到 SelectionBar 并改 Visibility
        private void NavMenuList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            UpdateSelectionBars(NavMenuList);
            // 主菜单选中时清空 footer 选中
            if (NavMenuList.SelectedIndex >= 0) NavFooterList.SelectedIndex = -1;
        }

        private void NavFooterList_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            UpdateSelectionBars(NavFooterList);
            // footer 选中时清空主菜单选中
            if (NavFooterList.SelectedIndex >= 0) NavMenuList.SelectedIndex = -1;
        }

        // 遍历 ListView 的 containers，更新 SelectionBar 可见性
        private void UpdateSelectionBars(ListView list)
        {
            try
            {
                for (int i = 0; i < list.Items.Count; i++)
                {
                    var container = list.ContainerFromIndex(i) as ListViewItem;
                    if (container == null) continue;
                    var bar = FindChildByName<Windows.UI.Xaml.Shapes.Rectangle>(container, "SelectionBar");
                    if (bar != null)
                    {
                        bar.Visibility = (i == list.SelectedIndex) ? Visibility.Visible : Visibility.Collapsed;
                    }
                }
            }
            catch { }
        }

        private static T FindChildByName<T>(DependencyObject parent, string name) where T : DependencyObject
        {
            int count = VisualTreeHelper.GetChildrenCount(parent);
            for (int i = 0; i < count; i++)
            {
                var child = VisualTreeHelper.GetChild(parent, i);
                if (child is FrameworkElement fe && fe.Name == name && fe is T t) return t;
                var found = FindChildByName<T>(child, name);
                if (found != null) return found;
            }
            return null;
        }

        // v261116-15: 菜单项点击
        private void NavMenuList_ItemClick(object sender, ItemClickEventArgs e)
        {
            var item = e.ClickedItem as NavItem;
            if (item == null) return;
            // 设置 SelectedIndex 会触发 SelectionChanged → 自动更新竖条
            for (int i = 0; i < NavMenuList.Items.Count; i++)
            {
                if ((NavMenuList.Items[i] as NavItem)?.Tag == item.Tag)
                {
                    NavMenuList.SelectedIndex = i;
                    break;
                }
            }
            switch (item.Tag)
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
            }
            if (Window.Current.Bounds.Width < 720) NavSplit.IsPaneOpen = false;
        }

        // v261116-15: 底部菜单（设置）点击
        private void NavFooterList_ItemClick(object sender, ItemClickEventArgs e)
        {
            var item = e.ClickedItem as NavItem;
            if (item == null) return;
            NavFooterList.SelectedIndex = 0;  // 触发 SelectionChanged
            if (item.Tag == "settings")
            {
                Frame.Navigate(typeof(SettingsPage));
                // 返回后默认选中聊天
                NavFooterList.SelectedIndex = -1;
                NavMenuList.SelectedIndex = 0;
            }
            if (Window.Current.Bounds.Width < 720) NavSplit.IsPaneOpen = false;
        }

        private void OnWindowSizeChanged(object sender, Windows.UI.Core.WindowSizeChangedEventArgs e)
        {
            double width = Window.Current.Bounds.Width;
            if (width >= 720)
            {
                NavSplit.DisplayMode = SplitViewDisplayMode.CompactInline;
                NavSplit.IsPaneOpen = true;
            }
            else
            {
                NavSplit.DisplayMode = SplitViewDisplayMode.CompactOverlay;
                NavSplit.IsPaneOpen = false;
            }
        }

        private void HamburgerBtn_Click(object sender, RoutedEventArgs e)
        {
            NavSplit.IsPaneOpen = !NavSplit.IsPaneOpen;
        }

        // v261116-13: ContainerContentChanging — 在 ListView item 容器化时渲染 Markdown
        // 用户消息：TextBlock 显示原文
        // AI 消息：RichTextBlock 显示 Markdown 渲染结果
        // 错误消息：TextBlock 红色显示
        private void MessageList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
        {
            if (args.Phase != 0) return;
            var msg = args.Item as ChatMessage;
            if (msg == null) return;

            // 找 ContentHost（DataTemplate 中 x:Name="ContentHost"）
            var container = args.ItemContainer as ListViewItem;
            if (container == null) return;
            var contentHost = FindChildByName<StackPanel>(container, "ContentHost");
            if (contentHost == null) return;

            contentHost.Children.Clear();

            if (msg.IsError)
            {
                // 错误消息：纯文本红色
                var tb = new TextBlock
                {
                    Text = msg.Content ?? "",
                    FontSize = 15,
                    TextWrapping = TextWrapping.Wrap,
                    LineHeight = 22,
                    Foreground = (Brush)Application.Current.Resources["SystemControlErrorTextForegroundBrush"]
                };
                contentHost.Children.Add(tb);
            }
            else if (msg.IsUser)
            {
                // 用户消息：纯文本白色（在 accent 色气泡上）
                var tb = new TextBlock
                {
                    Text = msg.Content ?? "",
                    FontSize = 15,
                    TextWrapping = TextWrapping.Wrap,
                    LineHeight = 22,
                    Foreground = new SolidColorBrush(Colors.White)
                };
                contentHost.Children.Add(tb);
            }
            else
            {
                // AI 消息：Markdown 渲染
                try
                {
                    var rtl = MarkdownRenderer.Render(msg.Content ?? "", App.IsDarkMode());
                    contentHost.Children.Add(rtl);
                }
                catch
                {
                    // 兜底：渲染失败显示原文
                    var tb = new TextBlock
                    {
                        Text = msg.Content ?? "",
                        FontSize = 15,
                        TextWrapping = TextWrapping.Wrap,
                        LineHeight = 22
                    };
                    contentHost.Children.Add(tb);
                }
            }
        }

        // 递归查找子控件
        private static T FindChildByName<T>(DependencyObject parent, string name) where T : DependencyObject
        {
            int count = VisualTreeHelper.GetChildrenCount(parent);
            for (int i = 0; i < count; i++)
            {
                var child = VisualTreeHelper.GetChild(parent, i);
                if (child is FrameworkElement fe && fe.Name == name && fe is T t) return t;
                var found = FindChildByName<T>(child, name);
                if (found != null) return found;
            }
            return null;
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
            // 切换回聊天视图 — v261116-15: 用 NavMenuList.SelectedIndex 替代 ChatRadio
            NavMenuList.SelectedIndex = 0;
            MessageList.Visibility = Visibility.Visible;
            HistoryPanel.Visibility = Visibility.Collapsed;
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
