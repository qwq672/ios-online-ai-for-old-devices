using System;
using System.Collections.ObjectModel;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using Windows.UI;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
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
            ApplyTheme();
        }

        private void ApplyTheme()
        {
            bool dark = SettingsStore.DarkTheme;
            RootGrid.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
            foreach (var m in messages) m.Dark = dark;
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

            var userMsg = new ChatMessage { Role = "user", Content = text, IsUser = true, Dark = SettingsStore.DarkTheme };
            messages.Add(userMsg);

            var aiMsg = new ChatMessage { Role = "assistant", Content = "正在思考...", Dark = SettingsStore.DarkTheme };
            messages.Add(aiMsg);

            InputBox.Text = "";
            isStreaming = true;
            SendBtn.Content = "停止";
            SendBtn.Background = new SolidColorBrush(Color.FromArgb(255, 220, 80, 80));

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

        private void SettingsBtn_Click(object sender, RoutedEventArgs e)
        {
            Frame.Navigate(typeof(SettingsPage));
        }

        private void ThemeBtn_Click(object sender, RoutedEventArgs e)
        {
            SettingsStore.SetBool("dark_theme", !SettingsStore.DarkTheme);
            ApplyTheme();
        }

        private void ClearBtn_Click(object sender, RoutedEventArgs e)
        {
            if (messages.Count > 0)
            {
                messages.Clear();
            }
        }

        private async void HistoryBtn_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new ContentDialog
            {
                Title = "历史对话",
                PrimaryButtonText = "关闭",
                DefaultButton = ContentDialogButton.Primary,
                Width = 480
            };
            var panel = new StackPanel { Padding = new Thickness(0, 12, 0, 0) };
            var convs = await ConversationStore.ListConversationsAsync();
            if (convs.Count == 0)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = "暂无历史对话",
                    Margin = new Thickness(0, 20, 0, 0),
                    HorizontalAlignment = HorizontalAlignment.Center
                });
            }
            else
            {
                var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 400 };
                foreach (var c in convs)
                {
                    var itemPanel = new StackPanel { Padding = new Thickness(8, 6, 8, 6), Tag = c };
                    itemPanel.Children.Add(new TextBlock { Text = c.title, FontWeight = FontWeights.SemiBold, FontSize = 14, TextWrapping = TextWrapping.Wrap });
                    var dt = DateTimeOffset.FromUnixTimeSeconds(c.timestamp).LocalDateTime;
                    itemPanel.Children.Add(new TextBlock
                    {
                        Text = dt.ToString("yyyy-MM-dd HH:mm") + "  · " + c.messages.Count + " 条",
                        FontSize = 11,
                        Foreground = new SolidColorBrush(Colors.Gray),
                        Margin = new Thickness(0, 2, 0, 0)
                    });
                    list.Items.Add(itemPanel);
                }
                list.SelectionChanged += async (s, args) =>
                {
                    if (list.SelectedItem is StackPanel sp && sp.Tag is ConversationStore.StoredConversation sc)
                    {
                        await LoadConversationAsync(sc.id);
                        dialog.Hide();
                    }
                };
                panel.Children.Add(list);
            }
            dialog.Content = panel;
            await dialog.ShowAsync();
        }

        private async Task LoadConversationAsync(string id)
        {
            var conv = await ConversationStore.LoadConversationAsync(id);
            if (conv == null) return;
            messages.Clear();
            bool dark = SettingsStore.DarkTheme;
            foreach (var m in conv.messages)
            {
                messages.Add(new ChatMessage
                {
                    Role = m.role,
                    Content = m.content ?? "",
                    Thinking = m.thinking ?? "",
                    IsUser = (m.role == "user"),
                    Dark = dark
                });
            }
            ScrollToBottom();
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
                SendBtn.Background = new SolidColorBrush(Color.FromArgb(255, 0, 120, 215));

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
                SendBtn.Background = new SolidColorBrush(Color.FromArgb(255, 0, 120, 215));
                if (messages.Count > 0)
                {
                    var last = messages[messages.Count - 1];
                    last.IsError = true;
                    last.Content = "[错误] " + message;
                }
            });
        }
    }

    public class ChatMessage : INotifyPropertyChanged
    {
        private string role = "";
        private string content = "";
        private string thinking = "";
        private bool isUser;
        private bool isError;
        private bool dark;
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

        public bool Dark
        {
            get { return dark; }
            set
            {
                dark = value;
                OnPropertyChanged();
                OnPropertyChanged("BubbleBackground");
                OnPropertyChanged("ContentForeground");
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

        // === Spacer 宽度（用 GridLengthStarConverter 转 GridLength）===
        public string LeftSpacerWidth => isUser ? "*" : "0";
        public string RightSpacerWidth => isUser ? "0" : "*";
        public string BubbleWidth => "*";

        public Brush BubbleBackground
        {
            get
            {
                Color bg;
                if (isError)
                    bg = dark ? Color.FromArgb(255, 70, 30, 30) : Color.FromArgb(255, 252, 220, 220);
                else if (isUser)
                    bg = dark ? Color.FromArgb(255, 40, 80, 60) : Color.FromArgb(255, 220, 248, 198);
                else
                    bg = dark ? Color.FromArgb(255, 38, 38, 42) : Color.FromArgb(255, 248, 248, 248);
                return new SolidColorBrush(bg);
            }
        }

        public Brush ContentForeground
        {
            get
            {
                if (isError)
                    return new SolidColorBrush(dark ? Color.FromArgb(255, 255, 180, 180) : Color.FromArgb(255, 180, 30, 30));
                return new SolidColorBrush(dark ? Color.FromArgb(255, 240, 240, 240) : Color.FromArgb(255, 30, 30, 30));
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

    public class BoolToAlignmentConverter : Windows.UI.Xaml.Data.IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, string language)
        {
            if (value is bool b) return b ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            return HorizontalAlignment.Left;
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
