using System.Windows;
using DarktideVR.Launcher.Core;

namespace DarktideVR.Launcher
{
    public partial class App : Application
    {
        public App()
        {
            DispatcherUnhandledException += (sender, e) =>
            {
                Log.Error("Unhandled: " + e.Exception);
                MessageBox.Show("Something went wrong: " + e.Exception.Message + "\n\nDetails are in the Log tab.", Strings.WindowTitle,
                    MessageBoxButton.OK, MessageBoxImage.Error);
                e.Handled = true;
            };
        }
    }
}
