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
                // v261116-10: 主题跟随系统 — 用户可在设置中强制浅色/深色
                // ElementTheme.Default = 跟随系统（UWP 标准行为）
                ApplyUserTheme(rootFrame);
                Window.Current.Content = rootFrame;
            }
            if (rootFrame.Content == null)
            {
                rootFrame.Navigate(typeof(MainPage), e.Arguments);
            }
            Window.Current.Activate();
        }

        // v261116-10: 应用用户选择的主题
        // 0 = 跟随系统 (Default), 1 = 浅色 (Light), 2 = 深色 (Dark)
        public static void ApplyUserTheme(Frame rootFrame)
        {
            int mode = SettingsStore.ThemeMode;
            ElementTheme theme = ElementTheme.Default;
            if (mode == 1) theme = ElementTheme.Light;
            else if (mode == 2) theme = ElementTheme.Dark;
            rootFrame.RequestedTheme = theme;
        }

        // 全局重新应用主题（设置页切换时调用）
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
    }
}
