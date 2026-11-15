using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using AIAnyWhere.Services;

namespace AIAnyWhere
{
    sealed partial class App : Application
    {
        public App()
        {
            InitializeComponent();
        }

        protected override void OnLaunched(Windows.ApplicationModel.Activation.LaunchActivatedEventArgs e)
        {
            Frame rootFrame = Window.Current.Content as Frame;
            if (rootFrame == null)
            {
                rootFrame = new Frame();
                // 应用主题（启动时即生效）
                bool dark = SettingsStore.DarkTheme;
                rootFrame.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
                Window.Current.Content = rootFrame;
            }
            if (rootFrame.Content == null)
            {
                rootFrame.Navigate(typeof(MainPage), e.Arguments);
            }
            Window.Current.Activate();
        }
    }
}
