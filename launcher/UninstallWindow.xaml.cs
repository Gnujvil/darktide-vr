using System.Windows;

namespace DarktideVR.Launcher
{
    public partial class UninstallWindow : Window
    {
        public UninstallWindow()
        {
            InitializeComponent();
            Title = Heading.Text = Strings.UninstallTitle;
            Body.Text = Strings.UninstallBody;
            ModLoaderText.Text = Strings.UninstallModLoader;
            DataText.Text = Strings.UninstallData;
            CancelButton.Content = Strings.Cancel;
            ConfirmButton.Content = Strings.UninstallConfirm;
        }

        public bool RemoveModLoader => ModLoaderBox.IsChecked == true;
        public bool RemoveData => DataBox.IsChecked == true;

        void Confirm_Click(object sender, RoutedEventArgs e) => DialogResult = true;
    }
}
