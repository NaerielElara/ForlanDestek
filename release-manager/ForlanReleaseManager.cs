using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ForlanReleaseManager
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ManagerForm());
        }
    }

    internal sealed class ManagerForm : Form
    {
        private const string Repository = "NaerielElara/ForlanDestek";
        private readonly string _settingsPath;
        private readonly string _notesPath;
        private TextBox _repoRootBox;
        private ComboBox _versionMode;
        private TextBox _manualVersion;
        private CheckBox _generateNotes;
        private CheckBox _openFolderAfterBuild;
        private TextBox _releaseNotes;
        private TextBox _commitMessage;
        private TextBox _output;
        private Label _status;
        private Label _versionSummary;
        private Label _artifactSummary;
        private Button _checkButton;
        private Button _buildButton;
        private Button _releaseButton;
        private Button _pullButton;
        private Button _commitPushButton;
        private TabControl _tabs;
        private readonly List<Button> _operationButtons = new List<Button>();
        private bool _isRunning;

        public ManagerForm()
        {
            string executableDirectory = Path.GetDirectoryName(Application.ExecutablePath);
            DirectoryInfo parent = Directory.GetParent(executableDirectory);
            string defaultRoot = parent == null ? executableDirectory : parent.FullName;
            string appData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ForlanDestek");
            _settingsPath = Path.Combine(appData, "release-manager.conf");
            _notesPath = Path.Combine(appData, "release-notes-draft.md");

            Text = "Forlan Destek | Sürüm Yöneticisi";
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(840, 650);
            Size = new Size(1020, 760);
            BackColor = Color.FromArgb(244, 247, 251);
            Font = new Font("Segoe UI", 9F, FontStyle.Regular);

            ManagerSettings settings = LoadSettings(defaultRoot);

            TableLayoutPanel shell = new TableLayoutPanel();
            shell.Dock = DockStyle.Fill;
            shell.Padding = new Padding(18, 14, 18, 12);
            shell.ColumnCount = 1;
            shell.RowCount = 4;
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 62F));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 58F));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 30F));
            Controls.Add(shell);

            Panel header = new Panel();
            header.Dock = DockStyle.Fill;
            Label title = new Label();
            title.Text = "Forlan Destek";
            title.Font = new Font("Segoe UI Semibold", 20F, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(27, 42, 61);
            title.AutoSize = true;
            title.Location = new Point(0, 0);
            header.Controls.Add(title);
            Label subtitle = new Label();
            subtitle.Text = "Portable build, sürüm ayarları ve GitHub yayın yönetimi";
            subtitle.ForeColor = Color.FromArgb(91, 105, 123);
            subtitle.AutoSize = true;
            subtitle.Location = new Point(2, 36);
            header.Controls.Add(subtitle);
            shell.Controls.Add(header, 0, 0);

            Panel summary = new Panel();
            summary.Dock = DockStyle.Fill;
            summary.BackColor = Color.White;
            summary.Padding = new Padding(12, 5, 12, 5);
            _versionSummary = new Label();
            _versionSummary.AutoSize = true;
            _versionSummary.ForeColor = Color.FromArgb(27, 42, 61);
            _versionSummary.Location = new Point(12, 6);
            summary.Controls.Add(_versionSummary);
            _artifactSummary = new Label();
            _artifactSummary.AutoSize = true;
            _artifactSummary.ForeColor = Color.FromArgb(91, 105, 123);
            _artifactSummary.Location = new Point(12, 31);
            summary.Controls.Add(_artifactSummary);
            shell.Controls.Add(summary, 0, 1);

            TabControl tabs = new TabControl();
            tabs.Dock = DockStyle.Fill;
            tabs.Font = new Font("Segoe UI", 9F, FontStyle.Regular);
            _tabs = tabs;
            shell.Controls.Add(tabs, 0, 2);

            TabPage homePage = new TabPage("Genel");
            homePage.BackColor = Color.FromArgb(244, 247, 251);
            tabs.TabPages.Add(homePage);
            BuildHomePage(homePage, settings);

            TabPage releasePage = new TabPage("Sürüm ve notlar");
            releasePage.BackColor = Color.FromArgb(244, 247, 251);
            tabs.TabPages.Add(releasePage);
            BuildReleasePage(releasePage, settings);

            TabPage toolsPage = new TabPage("Araçlar ve ayarlar");
            toolsPage.BackColor = Color.FromArgb(244, 247, 251);
            tabs.TabPages.Add(toolsPage);
            BuildToolsPage(toolsPage, settings);

            TabPage logPage = new TabPage("İşlem günlüğü");
            logPage.BackColor = Color.FromArgb(244, 247, 251);
            tabs.TabPages.Add(logPage);
            BuildLogPage(logPage);

            _status = new Label();
            _status.Text = "Hazır";
            _status.Dock = DockStyle.Fill;
            _status.TextAlign = ContentAlignment.MiddleLeft;
            _status.ForeColor = Color.FromArgb(91, 105, 123);
            shell.Controls.Add(_status, 0, 3);

            _repoRootBox.TextChanged += delegate { RefreshProjectSummary(); SaveSettingsQuietly(); };
            _versionMode.SelectedIndexChanged += delegate { UpdateManualVersionVisibility(); SaveSettingsQuietly(); };
            _manualVersion.TextChanged += delegate { SaveSettingsQuietly(); };
            _commitMessage.TextChanged += delegate { SaveSettingsQuietly(); };
            _generateNotes.CheckedChanged += delegate { SaveSettingsQuietly(); };
            _openFolderAfterBuild.CheckedChanged += delegate { SaveSettingsQuietly(); };
            FormClosing += delegate { SaveSettingsQuietly(); };

            RefreshProjectSummary();
            UpdateManualVersionVisibility();
        }

        private void BuildHomePage(TabPage page, ManagerSettings settings)
        {
            TableLayoutPanel layout = CreatePageLayout();
            layout.RowCount = 4;
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            page.Controls.Add(layout);

            Label intro = CreateBodyLabel("Buradan build alabilir, release öncesi koşulları kontrol edebilir ve yayını başlatabilirsiniz.");
            layout.Controls.Add(intro, 0, 0);

            GroupBox projectGroup = new GroupBox();
            projectGroup.Text = "Proje ve build";
            projectGroup.Dock = DockStyle.Top;
            projectGroup.Padding = new Padding(12);
            TableLayoutPanel projectLayout = new TableLayoutPanel();
            projectLayout.Dock = DockStyle.Top;
            projectLayout.AutoSize = true;
            projectLayout.ColumnCount = 3;
            projectLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            projectLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            projectLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            projectLayout.RowCount = 2;
            projectLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            projectLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Label rootLabel = CreateBodyLabel("Kaynak klasörü");
            rootLabel.Margin = new Padding(3, 8, 10, 3);
            _repoRootBox = new TextBox();
            _repoRootBox.Dock = DockStyle.Top;
            _repoRootBox.Text = settings.RepoRoot;
            Button browseRoot = CreateSecondaryButton("Gözat…", 95);
            browseRoot.Click += delegate { BrowseProjectRoot(); };
            projectLayout.Controls.Add(rootLabel, 0, 0);
            projectLayout.Controls.Add(_repoRootBox, 1, 0);
            projectLayout.Controls.Add(browseRoot, 2, 0);
            Label repositoryLabel = CreateBodyLabel("GitHub deposu");
            repositoryLabel.Margin = new Padding(3, 8, 10, 3);
            Label repositoryValue = CreateBodyLabel(Repository);
            repositoryValue.ForeColor = Color.FromArgb(38, 105, 210);
            projectLayout.Controls.Add(repositoryLabel, 0, 1);
            projectLayout.Controls.Add(repositoryValue, 1, 1);
            projectGroup.Controls.Add(projectLayout);
            layout.Controls.Add(projectGroup, 0, 1);

            FlowLayoutPanel actions = new FlowLayoutPanel();
            actions.Dock = DockStyle.Top;
            actions.AutoSize = true;
            actions.WrapContents = true;
            actions.Padding = new Padding(0, 8, 0, 4);
            _checkButton = CreateButton("Ön koşulları denetle", Color.FromArgb(91, 105, 123), 190);
            _checkButton.Click += delegate { StartReleaseCheck(); };
            _operationButtons.Add(_checkButton);
            _buildButton = CreateButton("Build al", Color.FromArgb(38, 105, 210), 150);
            _buildButton.Click += delegate { StartBuild(); };
            _operationButtons.Add(_buildButton);
            _releaseButton = CreateButton("Release paylaş", Color.FromArgb(25, 135, 84), 170);
            _releaseButton.Click += delegate { StartRelease(); };
            _operationButtons.Add(_releaseButton);
            actions.Controls.Add(_checkButton);
            actions.Controls.Add(_buildButton);
            actions.Controls.Add(_releaseButton);
            layout.Controls.Add(actions, 0, 2);

            Label help = CreateBodyLabel("GitHub CLI oturumu açık olmalı. Release sırasında build başarılı olunca sürüm ve kaynak değişiklikleri otomatik olarak commit edilip GitHub’a gönderilir. Çıktılar İşlem günlüğü sekmesinde görünür.");
            help.MaximumSize = new Size(860, 0);
            help.AutoSize = true;
            help.ForeColor = Color.FromArgb(91, 105, 123);
            layout.Controls.Add(help, 0, 3);
        }

        private void BuildReleasePage(TabPage page, ManagerSettings settings)
        {
            TableLayoutPanel layout = CreatePageLayout();
            layout.RowCount = 5;
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.Controls.Add(layout);

            Label intro = CreateBodyLabel("Yayın sürümünü seçin. Otomatik seçenek bekleyen mevcut sürümü kullanır; yoksa minor sürümü artırır.");
            intro.MaximumSize = new Size(880, 0);
            intro.AutoSize = true;
            layout.Controls.Add(intro, 0, 0);

            GroupBox versionGroup = new GroupBox();
            versionGroup.Text = "Sürüm numarası";
            versionGroup.Dock = DockStyle.Top;
            versionGroup.Padding = new Padding(12);
            TableLayoutPanel versionLayout = new TableLayoutPanel();
            versionLayout.Dock = DockStyle.Top;
            versionLayout.AutoSize = true;
            versionLayout.ColumnCount = 2;
            versionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            versionLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            versionLayout.RowCount = 3;
            versionLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            versionLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            versionLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            versionLayout.Controls.Add(CreateBodyLabel("Sürüm politikası"), 0, 0);
            _versionMode = new ComboBox();
            _versionMode.DropDownStyle = ComboBoxStyle.DropDownList;
            _versionMode.Width = 330;
            _versionMode.Items.AddRange(new object[] {
                "Otomatik (önerilen)",
                "Patch artır (1.2.3 → 1.2.4)",
                "Minor artır (1.2.3 → 1.3.0)",
                "Major artır (1.2.3 → 2.0.0)",
                "Sürümü elle gir"
            });
            int selectedMode = settings.VersionMode;
            if (selectedMode < 0 || selectedMode >= _versionMode.Items.Count)
                selectedMode = 0;
            _versionMode.SelectedIndex = selectedMode;
            versionLayout.Controls.Add(_versionMode, 1, 0);
            versionLayout.Controls.Add(CreateBodyLabel("Elle girilen sürüm"), 0, 1);
            _manualVersion = new TextBox();
            _manualVersion.Width = 180;
            _manualVersion.Text = settings.ManualVersion;
            versionLayout.Controls.Add(_manualVersion, 1, 1);
            Label modeHint = CreateBodyLabel("Bekleyen yerel sürüm kullanılır; kaynak ve yayın sürümü aynıysa seçtiğiniz artış uygulanır.");
            modeHint.ForeColor = Color.FromArgb(91, 105, 123);
            versionLayout.Controls.Add(modeHint, 1, 2);
            versionGroup.Controls.Add(versionLayout);
            layout.Controls.Add(versionGroup, 0, 1);

            _generateNotes = new CheckBox();
            _generateNotes.Text = "GitHub commit ve PR bilgilerinden otomatik yayın notu oluştur";
            _generateNotes.Checked = settings.GenerateNotes;
            _generateNotes.AutoSize = true;
            _generateNotes.Margin = new Padding(3, 12, 3, 8);
            layout.Controls.Add(_generateNotes, 0, 2);

            GroupBox notesGroup = new GroupBox();
            notesGroup.Text = "Ek yayın notları (isteğe bağlı)";
            notesGroup.Dock = DockStyle.Fill;
            notesGroup.Padding = new Padding(10);
            _releaseNotes = new TextBox();
            _releaseNotes.Dock = DockStyle.Fill;
            _releaseNotes.Multiline = true;
            _releaseNotes.AcceptsReturn = true;
            _releaseNotes.AcceptsTab = true;
            _releaseNotes.ScrollBars = ScrollBars.Vertical;
            _releaseNotes.WordWrap = true;
            _releaseNotes.Font = new Font("Segoe UI", 9F, FontStyle.Regular);
            _releaseNotes.Text = settings.ReleaseNotes;
            notesGroup.Controls.Add(_releaseNotes);
            layout.Controls.Add(notesGroup, 0, 3);

            Button saveDraft = CreateSecondaryButton("Yayın taslağını kaydet", 180);
            saveDraft.Click += delegate
            {
                try
                {
                    SaveSettings();
                    AppendOutput("Sürüm ayarları ve yayın notu taslağı kaydedildi.");
                    _status.Text = "Taslak kaydedildi";
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Taslak kaydedilemedi: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };
            layout.Controls.Add(saveDraft, 0, 4);
        }

        private void BuildToolsPage(TabPage page, ManagerSettings settings)
        {
            TableLayoutPanel layout = CreatePageLayout();
            layout.RowCount = 5;
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            page.Controls.Add(layout);

            Label intro = CreateBodyLabel("Bu uygulama build ve release betiklerini sizin yerinize çalıştırır. Betikleri ayrıca açmanız gerekmez.");
            intro.MaximumSize = new Size(880, 0);
            intro.AutoSize = true;
            layout.Controls.Add(intro, 0, 0);

            GroupBox outputGroup = new GroupBox();
            outputGroup.Text = "Build çıktısı";
            outputGroup.Dock = DockStyle.Top;
            outputGroup.Padding = new Padding(12);
            _openFolderAfterBuild = new CheckBox();
            _openFolderAfterBuild.Text = "Build başarılı olunca dist klasörünü aç";
            _openFolderAfterBuild.Checked = settings.OpenFolderAfterBuild;
            _openFolderAfterBuild.AutoSize = true;
            outputGroup.Controls.Add(_openFolderAfterBuild);
            layout.Controls.Add(outputGroup, 0, 1);

            GroupBox sourceGroup = new GroupBox();
            sourceGroup.Text = "GitHub kaynak kodu";
            sourceGroup.Dock = DockStyle.Top;
            sourceGroup.Padding = new Padding(12);
            TableLayoutPanel sourceLayout = new TableLayoutPanel();
            sourceLayout.Dock = DockStyle.Top;
            sourceLayout.AutoSize = true;
            sourceLayout.ColumnCount = 2;
            sourceLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            sourceLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            sourceLayout.RowCount = 2;
            sourceLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            sourceLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            sourceLayout.Controls.Add(CreateBodyLabel("Commit mesajı"), 0, 0);
            _commitMessage = new TextBox();
            _commitMessage.Dock = DockStyle.Top;
            _commitMessage.Text = settings.CommitMessage;
            sourceLayout.Controls.Add(_commitMessage, 1, 0);
            FlowLayoutPanel sourceActions = new FlowLayoutPanel();
            sourceActions.Dock = DockStyle.Top;
            sourceActions.AutoSize = true;
            sourceActions.Padding = new Padding(0, 5, 0, 0);
            _pullButton = CreateSecondaryButton("GitHub’dan kaynak çek", 200);
            _pullButton.Click += delegate { StartSourcePull(); };
            _operationButtons.Add(_pullButton);
            _commitPushButton = CreateSecondaryButton("Değişiklikleri commit et ve push et", 260);
            _commitPushButton.Click += delegate { StartSourceCommitPush(); };
            _operationButtons.Add(_commitPushButton);
            sourceActions.Controls.Add(_pullButton);
            sourceActions.Controls.Add(_commitPushButton);
            sourceLayout.Controls.Add(sourceActions, 1, 1);
            sourceGroup.Controls.Add(sourceLayout);
            layout.Controls.Add(sourceGroup, 0, 2);

            FlowLayoutPanel tools = new FlowLayoutPanel();
            tools.Dock = DockStyle.Top;
            tools.AutoSize = true;
            tools.WrapContents = true;
            tools.Padding = new Padding(0, 8, 0, 4);
            Button githubLogin = CreateSecondaryButton("GitHub / Git girişini ayarla", 220);
            githubLogin.Click += delegate { StartGitHubLogin(); };
            Button outputFolder = CreateSecondaryButton("dist klasörünü aç", 160);
            outputFolder.Click += delegate { OpenOutputFolder(); };
            Button buildLog = CreateSecondaryButton("Build günlüğünü aç", 165);
            buildLog.Click += delegate { OpenBuildLog(); };
            Button releasePage = CreateSecondaryButton("GitHub Release sayfası", 190);
            releasePage.Click += delegate { OpenReleasePage(); };
            tools.Controls.Add(githubLogin);
            tools.Controls.Add(outputFolder);
            tools.Controls.Add(buildLog);
            tools.Controls.Add(releasePage);
            layout.Controls.Add(tools, 0, 3);

            Label details = CreateBodyLabel("GitHub deposu güncelleme istemcisiyle aynı kalır: " + Repository + ". GitHub CLI ilk kullanımda oturum açmalı ve release oluşturma iznine sahip olmalıdır.");
            details.MaximumSize = new Size(880, 0);
            details.AutoSize = true;
            details.ForeColor = Color.FromArgb(91, 105, 123);
            layout.Controls.Add(details, 0, 4);
        }

        private void BuildLogPage(TabPage page)
        {
            TableLayoutPanel layout = CreatePageLayout();
            layout.RowCount = 2;
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            page.Controls.Add(layout);

            _output = new TextBox();
            _output.Dock = DockStyle.Fill;
            _output.Multiline = true;
            _output.ReadOnly = true;
            _output.WordWrap = false;
            _output.ScrollBars = ScrollBars.Both;
            _output.Font = new Font("Consolas", 9F, FontStyle.Regular);
            _output.BackColor = Color.White;
            _output.BorderStyle = BorderStyle.FixedSingle;
            layout.Controls.Add(_output, 0, 0);

            FlowLayoutPanel actions = new FlowLayoutPanel();
            actions.Dock = DockStyle.Top;
            actions.AutoSize = true;
            actions.Padding = new Padding(0, 8, 0, 0);
            Button clear = CreateSecondaryButton("Günlüğü temizle", 145);
            clear.Click += delegate { _output.Clear(); };
            Button save = CreateSecondaryButton("Günlüğü dosyaya kaydet…", 210);
            save.Click += delegate { SaveLog(); };
            actions.Controls.Add(clear);
            actions.Controls.Add(save);
            layout.Controls.Add(actions, 0, 1);
        }

        private static TableLayoutPanel CreatePageLayout()
        {
            TableLayoutPanel layout = new TableLayoutPanel();
            layout.Dock = DockStyle.Fill;
            layout.Padding = new Padding(14);
            layout.ColumnCount = 1;
            layout.RowCount = 0;
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            return layout;
        }

        private static Label CreateBodyLabel(string text)
        {
            Label label = new Label();
            label.Text = text;
            label.AutoSize = true;
            label.ForeColor = Color.FromArgb(45, 59, 76);
            label.Margin = new Padding(3, 6, 8, 6);
            return label;
        }

        private static Button CreateButton(string text, Color color, int width)
        {
            Button button = new Button();
            button.Text = text;
            button.Width = width;
            button.Height = 42;
            button.Margin = new Padding(0, 0, 10, 8);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.BackColor = color;
            button.ForeColor = Color.White;
            button.Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold);
            button.Cursor = Cursors.Hand;
            return button;
        }

        private static Button CreateSecondaryButton(string text, int width)
        {
            Button button = new Button();
            button.Text = text;
            button.Width = width;
            button.Height = 32;
            button.Margin = new Padding(3, 4, 8, 4);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Color.FromArgb(207, 216, 226);
            button.BackColor = Color.White;
            button.ForeColor = Color.FromArgb(45, 59, 76);
            button.Cursor = Cursors.Hand;
            return button;
        }

        private void BrowseProjectRoot()
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Forlan Destek kaynak kodunun bulunduğu klasörü seçin.";
                dialog.SelectedPath = _repoRootBox.Text;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                    _repoRootBox.Text = dialog.SelectedPath;
            }
        }

        private void StartBuild()
        {
            SaveSettingsQuietly();
            RunScript("build-portable.ps1", new string[] { "-NoPause", "-SkipReleaseManager" }, "Build al", true);
        }

        private void StartReleaseCheck()
        {
            SaveSettingsQuietly();
            List<string> arguments = BuildReleaseArguments();
            arguments.Add("-WhatIf");
            RunScript("release-portable.ps1", arguments, "Ön koşul kontrolü", false);
        }

        private void StartRelease()
        {
            SaveSettingsQuietly();
            List<string> arguments = BuildReleaseArguments();
            RunScript("release-portable.ps1", arguments, "Release paylaş", false);
        }

        private void StartSourcePull()
        {
            SaveSettingsQuietly();
            RunScript("release-manager\\git-source.ps1", new string[] { "-Action", "Pull" }, "GitHub’dan kaynak çek", false);
        }

        private void StartSourceCommitPush()
        {
            string message = _commitMessage.Text.Trim();
            if (String.IsNullOrWhiteSpace(message))
            {
                MessageBox.Show(this, "Önce commit mesajı girin.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            DialogResult result = MessageBox.Show(
                this,
                "Kaynak klasöründeki tüm Git değişiklikleri commit edilip GitHub’a gönderilecek. Devam etmeden önce dosyaları Ön koşul kontrolü ve İşlem günlüğü sekmesinden gözden geçirin.\n\nCommit mesajı: " + message,
                "Kaynak değişikliklerini gönder",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);
            if (result != DialogResult.Yes)
                return;

            SaveSettingsQuietly();
            RunScript(
                "release-manager\\git-source.ps1",
                new string[] { "-Action", "CommitPush", "-CommitMessage", message },
                "Kaynak değişikliklerini push et",
                false);
        }

        private List<string> BuildReleaseArguments()
        {
            List<string> arguments = new List<string>();
            arguments.Add("-VersionMode");
            arguments.Add(GetVersionModeValue());
            if (GetVersionModeValue() == "Manual")
            {
                arguments.Add("-ManualVersion");
                arguments.Add(_manualVersion.Text.Trim());
            }
            arguments.Add("-NotesFile");
            arguments.Add(WriteNotesDraft());
            if (!_generateNotes.Checked)
                arguments.Add("-SkipGeneratedNotes");
            return arguments;
        }

        private string GetVersionModeValue()
        {
            switch (_versionMode.SelectedIndex)
            {
                case 1: return "Patch";
                case 2: return "Minor";
                case 3: return "Major";
                case 4: return "Manual";
                default: return "Auto";
            }
        }

        private string WriteNotesDraft()
        {
            string directory = Path.GetDirectoryName(_notesPath);
            Directory.CreateDirectory(directory);
            File.WriteAllText(_notesPath, _releaseNotes.Text, new UTF8Encoding(false));
            return _notesPath;
        }

        private void RunScript(string scriptName, IList<string> arguments, string actionName, bool openOutputOnSuccess)
        {
            if (_isRunning)
                return;

            string repoRoot = GetRepoRoot();
            string scriptPath = Path.Combine(repoRoot, scriptName);
            if (!Directory.Exists(repoRoot) || !File.Exists(scriptPath))
            {
                AppendOutput("Kaynak klasörü veya betik bulunamadı: " + scriptPath);
                _status.Text = "Kaynak klasörünü kontrol edin";
                return;
            }

            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
                powershell = "powershell.exe";

            List<string> commandArguments = new List<string>();
            commandArguments.Add("-NoLogo");
            commandArguments.Add("-NoProfile");
            commandArguments.Add("-ExecutionPolicy");
            commandArguments.Add("Bypass");
            commandArguments.Add("-File");
            commandArguments.Add(scriptPath);
            foreach (string argument in arguments)
                commandArguments.Add(argument);

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powershell;
            startInfo.Arguments = JoinCommandLineArguments(commandArguments);
            startInfo.WorkingDirectory = repoRoot;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;

            try
            {
                Process process = new Process();
                process.StartInfo = startInfo;
                process.EnableRaisingEvents = true;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                        AppendOutput(e.Data);
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                        AppendOutput(e.Data);
                };
                process.Exited += delegate
                {
                    process.WaitForExit();
                    int exitCode = process.ExitCode;
                    if (!IsDisposed && IsHandleCreated)
                    {
                        BeginInvoke((MethodInvoker)delegate
                        {
                            _isRunning = false;
                            SetOperationButtonsEnabled(true);
                            _status.Text = exitCode == 0
                                ? actionName + " tamamlandı"
                                : actionName + " hata ile tamamlandı (kod " + exitCode + ")";
                            AppendOutput(_status.Text);
                            process.Dispose();
                            if (exitCode == 0 && (actionName == "GitHub’dan kaynak çek" ||
                                actionName == "Kaynak değişikliklerini push et" || actionName == "Release paylaş"))
                                RefreshProjectSummary();
                            if (exitCode == 0 && openOutputOnSuccess && _openFolderAfterBuild.Checked)
                                OpenOutputFolder();
                            if (exitCode == 0 && actionName == "Release paylaş")
                            {
                                _releaseNotes.Clear();
                                SaveSettingsQuietly();
                            }
                        });
                    }
                    else
                    {
                        process.Dispose();
                    }
                };

                AppendOutput(actionName + " başlatılıyor...");
                _isRunning = true;
                SetOperationButtonsEnabled(false);
                _status.Text = actionName + " çalışıyor";
                _tabs.SelectedTab = _tabs.TabPages[3];
                if (!process.Start())
                    throw new InvalidOperationException("PowerShell işlemi başlatılamadı.");
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                _isRunning = false;
                SetOperationButtonsEnabled(true);
                _status.Text = "İşlem başlatılamadı";
                AppendOutput(ex.Message);
            }
        }

        private void SetOperationButtonsEnabled(bool enabled)
        {
            foreach (Button button in _operationButtons)
                button.Enabled = enabled;
        }

        private void RefreshProjectSummary()
        {
            string root = GetRepoRoot();
            string version = "bulunamadı";
            string buildNumber = "?";
            try
            {
                if (String.IsNullOrWhiteSpace(root))
                    throw new ArgumentException("Kaynak klasörü seçilmedi.");
                string cargo = File.ReadAllText(Path.Combine(root, "Cargo.toml"));
                Match cargoMatch = Regex.Match(cargo, "(?m)^version\\s*=\\s*\"(?<v>\\d+\\.\\d+\\.\\d+)\"\\s*$");
                if (cargoMatch.Success)
                    version = cargoMatch.Groups["v"].Value;
                string pubspec = File.ReadAllText(Path.Combine(root, "flutter", "pubspec.yaml"));
                Match pubspecMatch = Regex.Match(pubspec, "(?m)^version:\\s*\\d+\\.\\d+\\.\\d+\\+(?<b>\\d+)\\s*$");
                if (pubspecMatch.Success)
                    buildNumber = pubspecMatch.Groups["b"].Value;
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            catch (ArgumentException)
            {
            }

            _versionSummary.Text = "Kaynak sürümü: " + version + "   |   Flutter build: " + buildNumber + "   |   GitHub: " + Repository;
            _artifactSummary.Text = "Çıktı: dist\\ForlanDestek-" + version + "-portable.exe";
        }

        private void UpdateManualVersionVisibility()
        {
            bool manual = _versionMode.SelectedIndex == 4;
            _manualVersion.Enabled = manual;
            _manualVersion.BackColor = manual ? Color.White : Color.FromArgb(236, 240, 244);
        }

        private void OpenOutputFolder()
        {
            string root = GetRepoRoot();
            if (String.IsNullOrWhiteSpace(root))
            {
                _status.Text = "Önce kaynak klasörünü seçin";
                return;
            }
            string path = Path.Combine(root, "dist");
            if (!Directory.Exists(path))
                Directory.CreateDirectory(path);
            OpenPath(path);
        }

        private void OpenBuildLog()
        {
            string root = GetRepoRoot();
            if (String.IsNullOrWhiteSpace(root))
            {
                _status.Text = "Önce kaynak klasörünü seçin";
                return;
            }
            string path = Path.Combine(root, "build-portable.log");
            if (!File.Exists(path))
            {
                MessageBox.Show(this, "Henüz build günlüğü oluşturulmadı.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            OpenPath(path);
        }

        private void OpenReleasePage()
        {
            OpenPath("https://github.com/" + Repository + "/releases");
        }

        private void StartGitHubLogin()
        {
            try
            {
                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = "cmd.exe";
                startInfo.Arguments = "/k gh auth login --hostname github.com && gh auth setup-git --hostname github.com";
                string root = GetRepoRoot();
                startInfo.WorkingDirectory = Directory.Exists(root)
                    ? root
                    : Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = false;
                Process.Start(startInfo);
                _status.Text = "GitHub CLI oturum penceresi açıldı";
            }
            catch (Exception ex)
            {
                AppendOutput("GitHub oturumu açılamadı: " + ex.Message);
                _status.Text = "GitHub CLI bulunamadı veya başlatılamadı";
            }
        }

        private void SaveLog()
        {
            using (SaveFileDialog dialog = new SaveFileDialog())
            {
                dialog.Title = "İşlem günlüğünü kaydet";
                dialog.Filter = "Metin dosyası (*.txt)|*.txt|Tüm dosyalar (*.*)|*.*";
                dialog.FileName = "ForlanReleaseManager-log.txt";
                if (dialog.ShowDialog(this) == DialogResult.OK)
                    File.WriteAllText(dialog.FileName, _output.Text, new UTF8Encoding(false));
            }
        }

        private void OpenPath(string path)
        {
            try
            {
                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = path;
                startInfo.UseShellExecute = true;
                Process.Start(startInfo);
            }
            catch (Exception ex)
            {
                AppendOutput("Açılamadı: " + path + " — " + ex.Message);
            }
        }

        private string GetRepoRoot()
        {
            string path = _repoRootBox.Text.Trim();
            if (String.IsNullOrWhiteSpace(path))
                return "";
            try { return Path.GetFullPath(path); }
            catch (ArgumentException) { return path; }
        }

        private void SaveSettingsQuietly()
        {
            try { SaveSettings(); }
            catch (Exception ex)
            {
                if (_output != null)
                    AppendOutput("Ayarlar kaydedilemedi: " + ex.Message);
            }
        }

        private void SaveSettings()
        {
            string directory = Path.GetDirectoryName(_settingsPath);
            Directory.CreateDirectory(directory);
            List<string> lines = new List<string>();
            lines.Add(Encode(_repoRootBox.Text.Trim()));
            lines.Add(_versionMode.SelectedIndex.ToString());
            lines.Add(Encode(_manualVersion.Text.Trim()));
            lines.Add(_generateNotes.Checked ? "1" : "0");
            lines.Add(_openFolderAfterBuild.Checked ? "1" : "0");
            lines.Add(Encode(_releaseNotes.Text));
            lines.Add(Encode(_commitMessage.Text.Trim()));
            string temporary = _settingsPath + ".tmp";
            File.WriteAllLines(temporary, lines.ToArray(), new UTF8Encoding(false));
            if (File.Exists(_settingsPath))
                File.Delete(_settingsPath);
            File.Move(temporary, _settingsPath);
        }

        private static ManagerSettings LoadSettings(string defaultRoot)
        {
            ManagerSettings settings = new ManagerSettings();
            settings.RepoRoot = defaultRoot;
            settings.VersionMode = 0;
            settings.ManualVersion = "";
            settings.GenerateNotes = true;
            settings.OpenFolderAfterBuild = true;
            settings.ReleaseNotes = "";
            settings.CommitMessage = "Update Forlan Destek source";
            string path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ForlanDestek", "release-manager.conf");
            if (!File.Exists(path))
            {
                try
                {
                    string cargo = File.ReadAllText(Path.Combine(defaultRoot, "Cargo.toml"));
                    Match version = Regex.Match(cargo, "(?m)^version\\s*=\\s*\"(?<v>\\d+\\.\\d+\\.\\d+)\"\\s*$");
                    if (version.Success)
                    {
                        string notesPath = Path.Combine(defaultRoot, "release-notes", version.Groups["v"].Value + ".md");
                        if (File.Exists(notesPath))
                            settings.ReleaseNotes = File.ReadAllText(notesPath, Encoding.UTF8);
                    }
                }
                catch (IOException)
                {
                }
                catch (ArgumentException)
                {
                }
                return settings;
            }
            try
            {
                string[] lines = File.ReadAllLines(path);
                if (lines.Length > 0) settings.RepoRoot = Decode(lines[0], defaultRoot);
                if (lines.Length > 1) Int32.TryParse(lines[1], out settings.VersionMode);
                if (lines.Length > 2) settings.ManualVersion = Decode(lines[2], "");
                if (lines.Length > 3) settings.GenerateNotes = lines[3] == "1";
                if (lines.Length > 4) settings.OpenFolderAfterBuild = lines[4] == "1";
                if (lines.Length > 5) settings.ReleaseNotes = Decode(lines[5], "");
                if (lines.Length > 6) settings.CommitMessage = Decode(lines[6], settings.CommitMessage);
            }
            catch (IOException)
            {
                settings.RepoRoot = defaultRoot;
            }
            catch (FormatException)
            {
                settings.RepoRoot = defaultRoot;
            }
            return settings;
        }

        private static string Encode(string value)
        {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? ""));
        }

        private static string Decode(string value, string fallback)
        {
            try { return Encoding.UTF8.GetString(Convert.FromBase64String(value)); }
            catch { return fallback; }
        }

        private void AppendOutput(string text)
        {
            if (IsDisposed || !IsHandleCreated)
                return;
            if (InvokeRequired)
            {
                try { BeginInvoke((MethodInvoker)delegate { AppendOutput(text); }); }
                catch (InvalidOperationException) { }
                return;
            }
            if (_output.TextLength > 400000)
                _output.Clear();
            _output.AppendText(text + Environment.NewLine);
            _output.SelectionStart = _output.TextLength;
            _output.ScrollToCaret();
        }

        private static string JoinCommandLineArguments(IList<string> arguments)
        {
            StringBuilder commandLine = new StringBuilder();
            for (int i = 0; i < arguments.Count; i++)
            {
                if (i > 0)
                    commandLine.Append(' ');
                commandLine.Append(QuoteCommandLineArgument(arguments[i]));
            }
            return commandLine.ToString();
        }

        private static string QuoteCommandLineArgument(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
                return argument;
            StringBuilder quoted = new StringBuilder();
            quoted.Append('"');
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                }
                else if (character == '"')
                {
                    quoted.Append('\\', (backslashes * 2) + 1);
                    quoted.Append('"');
                    backslashes = 0;
                }
                else
                {
                    quoted.Append('\\', backslashes);
                    quoted.Append(character);
                    backslashes = 0;
                }
            }
            quoted.Append('\\', backslashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        private sealed class ManagerSettings
        {
            public string RepoRoot;
            public int VersionMode;
            public string ManualVersion;
            public bool GenerateNotes;
            public bool OpenFolderAfterBuild;
            public string ReleaseNotes;
            public string CommitMessage;
        }
    }
}
