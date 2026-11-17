using System;
using System.Threading.Tasks;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.Storage;
using AIAnyWhere.Services;

namespace AIAnyWhere
{
    sealed partial class App : Application
    {
        public App()
        {
            InitializeComponent();
            // v261116-16: 全局未处理异常捕获 — 写入日志文件便于调试启动闪退
            // 注意: UWP 不支持 AppDomain.CurrentDomain.UnhandledException（桌面 .NET 才有）
            UnhandledException += App_UnhandledException;
            TaskScheduler.UnobservedTaskException += TaskScheduler_UnobservedTaskException;
        }

        private async void App_UnhandledException(object sender, Windows.UI.Xaml.UnhandledExceptionEventArgs e)
        {
            e.Handled = true;
            try
            {
                var folder = ApplicationData.Current.LocalFolder;
                var file = await folder.CreateFileAsync("crash.log", CreationCollisionOption.OpenIfExists);
                await FileIO.AppendTextAsync(file, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] UNHANDLED: {e.Exception}\n\n");
            }
            catch { }
        }

        private async void TaskScheduler_UnobservedTaskException(object sender, System.Threading.Tasks.UnobservedTaskExceptionEventArgs e)
        {
            e.SetObserved();
            try
            {
                var folder = ApplicationData.Current.LocalFolder;
                var file = await folder.CreateFileAsync("crash.log", CreationCollisionOption.OpenIfExists);
                await FileIO.AppendTextAsync(file, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] TASK: {e.Exception}\n\n");
            }
            catch { }
        }

        protected override void OnLaunched(Windows.ApplicationModel.Activation.LaunchActivatedEventArgs e)
        {
            try
            {
                Frame rootFrame = Window.Current.Content as Frame;
                if (rootFrame == null)
                {
                    rootFrame = new Frame();
                    ApplyUserTheme(rootFrame);
                    Window.Current.Content = rootFrame;
                }
                if (rootFrame.Content == null)
                {
                    rootFrame.Navigate(typeof(MainPage), e.Arguments);
                }
                Window.Current.Activate();
            }
            catch (Exception ex)
            {
                // 启动崩溃 — 写日志
                try
                {
                    var folder = ApplicationData.Current.LocalFolder;
                    var file = folder.CreateFileAsync("startup_crash.log", CreationCollisionOption.ReplaceExisting).AsTask().Result;
                    FileIO.WriteTextAsync(file, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] LAUNCH: {ex}").AsTask().Wait();
                }
                catch { }
                throw;
            }
        }

        public static void ApplyUserTheme(Frame rootFrame)
        {
            int mode = SettingsStore.ThemeMode;
            ElementTheme theme = ElementTheme.Default;
            if (mode == 1) theme = ElementTheme.Light;
            else if (mode == 2) theme = ElementTheme.Dark;
            rootFrame.RequestedTheme = theme;
        }

        public static void ReapplyTheme()
        {
            if (Window.Current.Content is FrameworkElement root)
            {
                int mode = SettingsStore.ThemeMode;
                ElementTheme theme = ElementTheme.Default;
                if (mode == 1) theme = ElementTheme.Light;
                else if (mode == 2) theme = ElementTheme.Dark;
                root.RequestedTheme = theme;
            }
        }

        public static bool IsDarkMode()
        {
            try
            {
                int mode = SettingsStore.ThemeMode;
                if (mode == 1) return false;
                if (mode == 2) return true;
                if (Window.Current.Content is FrameworkElement root)
                {
                    return root.ActualTheme == ElementTheme.Dark;
                }
                return Windows.UI.Xaml.Application.Current.RequestedTheme == ApplicationTheme.Dark;
            }
            catch { return false; }
        }
    }
}
