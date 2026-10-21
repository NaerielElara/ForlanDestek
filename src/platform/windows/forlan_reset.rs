use hbb_common::{
    anyhow::{anyhow, Context},
    log, ResultType,
};
use std::{
    fs,
    path::{Path, PathBuf},
};
use windows::Win32::{
    System::Com,
    UI::Shell::{
        FOLDERID_Desktop, FOLDERID_LocalAppData, SHGetKnownFolderPath, KF_FLAG_DEFAULT,
    },
};

#[path = "forlan_reset_files.rs"]
mod files;

const LAUNCHER_DIRECTORY: &str = "ForlanDestekLauncher";
pub const LAUNCHER_ENV: &str = "FORLAN_PORTABLE_LAUNCHER";

fn folder(id: &windows::core::GUID) -> ResultType<PathBuf> {
    let value = unsafe { SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) }?;
    let path = unsafe { value.to_string() };
    unsafe { Com::CoTaskMemFree(Some(value.0.cast())) };
    let path = PathBuf::from(path?);
    files::validate_path(&path)?;
    Ok(path)
}

fn mark_profile_preserved() -> ResultType<()> {
    let local = folder(&FOLDERID_LocalAppData)?;
    files::preserve_profiles_once(&local)?;
    Ok(())
}

pub fn prepare_startup() -> bool {
    if crate::get_app_name() != "ForlanDestek" {
        return true;
    }
    let executable = std::env::current_exe()
        .ok()
        .and_then(|path| path.file_stem().map(|v| v.to_string_lossy().into_owned()));
    if !executable
        .map(|name| name.eq_ignore_ascii_case("ForlanDestek"))
        .unwrap_or(false)
    {
        return true;
    }
    let first = std::env::args().nth(1);
    let runtime = matches!(
        first.as_deref(),
        None | Some(
            "--install"
                | "--silent-install"
                | "--tray"
                | "--service"
                | "--server"
                | "--cm"
                | "--connect"
                | "--file-transfer"
                | "--noinstall"
                | "--quick_support"
                | "--no-server"
                | "--elevate"
                | "--run-as-system"
        )
    ) || (first.as_deref() == Some("--import-config")
        && super::is_process_running_as_system(std::process::id()).unwrap_or(false));
    if !runtime {
        return true;
    }
    if let Err(error) = mark_profile_preserved() {
        eprintln!("Forlan Destek profile preparation failed: {error:#}");
        super::message_box("Forlan Destek kullanıcı verilerini koruyarak başlatılamadı. Klasör erişimini kontrol edip tekrar deneyin!");
        return false;
    }
    true
}

pub fn installed_cleanup_command(source: &str, path: &str) -> ResultType<String> {
    if crate::get_app_name() != "ForlanDestek" {
        return Ok(String::new());
    }
    super::validate_install_value(source)?;
    super::validate_install_value(path)?;
    Ok(format!(
        "\"{source}\" --forlan-clean-installed-assets \"{path}\" || exit /b 1"
    ))
}

pub fn start_portable_update(file: &str) -> ResultType<bool> {
    if crate::get_app_name() != "ForlanDestek" || super::is_installed() {
        return Ok(false);
    }
    use std::{os::windows::process::CommandExt, process::Command};
    Command::new(file)
        .arg("--update")
        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
        .spawn()?;
    Ok(true)
}

pub fn handle_maintenance_command() -> bool {
    if crate::get_app_name() != "ForlanDestek"
        || std::env::args().nth(1).as_deref() != Some("--forlan-clean-installed-assets")
    {
        return false;
    }
    let result = (|| -> ResultType<()> {
        let (_, installed, _, _) = super::get_install_info();
        let requested = std::env::args()
            .nth(2)
            .ok_or_else(|| anyhow!("Missing installation directory"))?;
        if Path::new(&requested) != Path::new(&installed) {
            return Err(anyhow!("Unexpected installation directory"));
        }
        let path = Path::new(&installed);
        files::validate_tree(path)?;
        mark_profile_preserved()?;
        files::remove_owned_tree(path, "data")?;
        Ok(())
    })();
    if let Err(error) = result {
        eprintln!("Forlan installed asset cleanup failed: {error:#}");
        std::process::exit(1);
    }
    true
}

pub fn finish_portable_update() -> ResultType<()> {
    let source =
        PathBuf::from(std::env::var(LAUNCHER_ENV).context("Portable package location is missing")?);
    files::validate_tree(&source)?;
    if !source.is_file()
        || source
            .extension()
            .and_then(|v| v.to_str())
            .map(|v| !v.eq_ignore_ascii_case("exe"))
            .unwrap_or(true)
    {
        return Err(anyhow!("Portable update source is not an executable file"));
    }
    let local = folder(&FOLDERID_LocalAppData)?;
    let launchers = local.join(LAUNCHER_DIRECTORY);
    files::validate_tree(&launchers)?;
    fs::create_dir_all(&launchers)?;
    let destination = launchers.join("ForlanDestek.exe");
    files::validate_tree(&destination)?;
    if source != destination {
        fs::copy(&source, &destination)?;
    }
    let shortcut = folder(&FOLDERID_Desktop)?.join("Forlan Destek.lnk");
    files::validate_tree(&shortcut)?;
    let actual_destination = fs::canonicalize(&destination)?;
    files::validate_tree(&actual_destination)?;
    let actual_destination = actual_destination.to_string_lossy();
    let destination_str = actual_destination
        .strip_prefix(r"\\?\")
        .unwrap_or(&actual_destination);
    let destination_str = Path::new(destination_str)
        .to_str()
        .ok_or_else(|| anyhow!("Portable launcher path is not Unicode"))?;
    let bytes = super::shortcut_bytes(destination_str, None, None)?;
    fs::write(&shortcut, bytes)?;
    mark_profile_preserved()?;
    log::info!(
        "Portable update launcher prepared: {}",
        destination.display()
    );
    launch_as_desktop_user(destination_str)?;
    Ok(())
}

fn launch_as_desktop_user(exe: &str) -> ResultType<()> {
    use windows::{
        core::{Interface, BSTR},
        Win32::{
            Foundation::RPC_E_CHANGED_MODE,
            System::{
                Com::{self, IDispatch, IServiceProvider},
                Variant::VARIANT,
            },
            UI::Shell::{
                IShellBrowser, IShellDispatch2, IShellFolderViewDual, IShellWindows,
                SID_STopLevelBrowser, ShellWindows, SVGIO_BACKGROUND, SWC_DESKTOP,
                SWFO_NEEDDISPATCH,
            },
        },
    };
    let initialized = unsafe { Com::CoInitializeEx(None, Com::COINIT_APARTMENTTHREADED) };
    if initialized.is_err() && initialized != RPC_E_CHANGED_MODE {
        initialized.ok()?;
    }
    let result = (|| -> ResultType<()> {
        let shell: IShellWindows =
            unsafe { Com::CoCreateInstance(&ShellWindows, None, Com::CLSCTX_LOCAL_SERVER) }?;
        let empty = VARIANT::default();
        let mut hwnd = 0;
        let dispatch = unsafe {
            shell.FindWindowSW(&empty, &empty, SWC_DESKTOP, &mut hwnd, SWFO_NEEDDISPATCH)
        }?;
        let provider: IServiceProvider = dispatch.cast()?;
        let browser: IShellBrowser = unsafe { provider.QueryService(&SID_STopLevelBrowser) }?;
        let view = unsafe { browser.QueryActiveShellView() }?;
        let background: IDispatch = unsafe { view.GetItemObject(SVGIO_BACKGROUND) }?;
        let folder: IShellFolderViewDual = background.cast()?;
        let application = unsafe { folder.Application() }?;
        let shell: IShellDispatch2 = application.cast()?;
        unsafe {
            shell.ShellExecute(
                &BSTR::from(exe),
                &empty,
                &empty,
                &VARIANT::from("open"),
                &VARIANT::from(1i32),
            )
        }?;
        Ok(())
    })();
    if initialized.is_ok() {
        unsafe { Com::CoUninitialize() };
    }
    result
}
