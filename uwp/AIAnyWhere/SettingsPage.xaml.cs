using System;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using AIAnyWhere.Services;

namespace AIAnyWhere
{
    public sealed partial class SettingsPage : Page
    {
        private bool _isLoading = true;

        public SettingsPage()
        {
            InitializeComponent();
            LoadSettings();
            _isLoading = false;
        }

        private void LoadSettings()
        {
            DarkSwitch.IsOn = SettingsStore.DarkTheme;
            StreamSwitch.IsOn = SettingsStore.Stream;
            ThinkingSwitch.IsOn = SettingsStore.ShowThinking;
            ApiKeyBox.Text = SettingsStore.ApiKey;
            BaseUrlBox.Text = SettingsStore.BaseUrl;
            ModelBox.Text = SettingsStore.Model;
            PromptBox.Text = SettingsStore.SystemPrompt;
            TempSlider.Value = SettingsStore.Temperature;
            MaxTokensBox.Text = SettingsStore.MaxTokens.ToString();

            // 服务商下拉
            ProviderCombo.Items.Clear();
            int selectedIdx = 0;
            string currentProvider = SettingsStore.Provider;
            for (int i = 0; i < SettingsStore.Providers.Count; i++)
            {
                var p = SettingsStore.Providers[i];
                ProviderCombo.Items.Add(p.Name);
                if (p.Id == currentProvider) selectedIdx = i;
            }
            ProviderCombo.SelectedIndex = selectedIdx;
        }

        private void SaveBtn_Click(object sender, RoutedEventArgs e)
        {
            SettingsStore.SetBool("dark_theme", DarkSwitch.IsOn);
            SettingsStore.SetBool("stream", StreamSwitch.IsOn);
            SettingsStore.SetBool("show_thinking", ThinkingSwitch.IsOn);
            SettingsStore.Set("api_key", ApiKeyBox.Text.Trim());
            SettingsStore.Set("base_url", BaseUrlBox.Text.Trim());
            SettingsStore.Set("model", ModelBox.Text.Trim());
            SettingsStore.Set("system_prompt", PromptBox.Text.Trim());
            SettingsStore.SetDouble("temperature", TempSlider.Value);

            int mt = 0;
            int.TryParse(MaxTokensBox.Text.Trim(), out mt);
            SettingsStore.SetInt("max_tokens", mt);

            // 服务商
            int idx = ProviderCombo.SelectedIndex;
            if (idx >= 0 && idx < SettingsStore.Providers.Count)
            {
                var p = SettingsStore.Providers[idx];
                SettingsStore.Set("provider", p.Id);
            }

            Frame.GoBack();
        }

        private void BackBtn_Click(object sender, RoutedEventArgs e)
        {
            Frame.GoBack();
        }

        // 当用户切换服务商时，自动填充 BaseUrl 和默认模型（如果 BaseUrl 为空）
        private void ProviderCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_isLoading) return;
            int idx = ProviderCombo.SelectedIndex;
            if (idx < 0 || idx >= SettingsStore.Providers.Count) return;
            var p = SettingsStore.Providers[idx];
            if (string.IsNullOrEmpty(BaseUrlBox.Text.Trim()) || BaseUrlBox.Text.Trim() == SettingsStore.BaseUrl)
            {
                BaseUrlBox.Text = p.BaseUrl;
            }
            if (string.IsNullOrEmpty(ModelBox.Text.Trim()) || ModelBox.Text.Trim() == SettingsStore.Model)
            {
                ModelBox.Text = p.DefaultModel;
            }
        }
    }
}
