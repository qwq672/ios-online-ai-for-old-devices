using Windows.Storage;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;

namespace AIAnyWhere
{
    public sealed partial class SettingsPage : Page
    {
        public SettingsPage()
        {
            InitializeComponent();
            var settings = ApplicationData.Current.LocalSettings;
            ApiKeyBox.Text = settings.Values["api_key"] as string ?? "";
            BaseUrlBox.Text = settings.Values["base_url"] as string ?? "https://api.openai.com/v1";
            ModelBox.Text = settings.Values["model"] as string ?? "gpt-3.5-turbo";
            PromptBox.Text = settings.Values["system_prompt"] as string ?? "You are a helpful assistant.";
            StreamSwitch.IsOn = (settings.Values["stream"] as bool?) ?? true;
        }

        private void SaveBtn_Click(object sender, RoutedEventArgs e)
        {
            var settings = ApplicationData.Current.LocalSettings;
            settings.Values["api_key"] = ApiKeyBox.Text.Trim();
            settings.Values["base_url"] = BaseUrlBox.Text.Trim();
            settings.Values["model"] = ModelBox.Text.Trim();
            settings.Values["system_prompt"] = PromptBox.Text.Trim();
            settings.Values["stream"] = StreamSwitch.IsOn;
            Frame.GoBack();
        }
    }
}
