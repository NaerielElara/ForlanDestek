use hbb_common::{anyhow::Context, config::Config, log, ResultType};
use serde::Deserialize;
use std::{
    collections::HashMap,
    ffi::c_void,
    os::windows::ffi::OsStrExt,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use windows::{
    core::{w, Interface, HSTRING, PCWSTR},
    Data::Xml::Dom::XmlDocument,
    Foundation::{DateTime, IReference, PropertyValue},
    Win32::{
        Foundation::{LPARAM, WPARAM},
        UI::{
            Shell::SetCurrentProcessExplicitAppUserModelID,
            WindowsAndMessaging::{FindWindowW, PostMessageW, RegisterWindowMessageW},
        },
    },
    UI::Notifications::{ToastNotification, ToastNotificationManager},
};
use winreg::{enums::HKEY_CURRENT_USER, RegKey};

const APP_ID: &str = "ForlanDestek.Support";
const TRAY_QUIT_MESSAGE: &str = "ForlanDestek.TrayQuit.v1";

#[link(name = "winmm")]
extern "system" {
    fn PlaySoundW(sound: *const u16, module: *mut c_void, flags: u32) -> i32;
}

#[link(name = "runtimeobject")]
extern "system" {
    fn RoInitialize(kind: u32) -> i32;
    fn RoUninitialize();
}

#[derive(Deserialize)]
struct Notification {
    title: String,
    body: String,
    #[serde(default)]
    sound: String,
}

pub fn handle_local_option(key: &str, value: &str) -> bool {
    if crate::get_app_name() != "ForlanDestek" || key != "forlan-support-notification" {
        return false;
    }
    match serde_json::from_str::<Notification>(value) {
        Ok(notification) => {
            std::thread::spawn(move || {
                if let Err(error) = show_notification(notification) {
                    hbb_common::throttled_log!(Duration::from_secs(30), warn, "Forlan notification failed: {error}");
                }
            });
        }
        Err(error) => hbb_common::throttled_log!(Duration::from_secs(30), warn, "Invalid Forlan notification: {error}"),
    }
    true
}

fn asset_path(name: &str) -> ResultType<PathBuf> {
    let executable = std::env::current_exe()?;
    let directory = executable
        .parent()
        .context("Application directory is unavailable")?;
    Ok(directory.join("data/flutter_assets/assets").join(name))
}

fn register_identity() -> ResultType<()> {
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(format!(r"Software\Classes\AppUserModelId\{APP_ID}"))?;
    key.set_value("DisplayName", &"Forlan Destek")?;
    key.set_value(
        "IconUri",
        &asset_path("icon.png")?.to_string_lossy().as_ref(),
    )?;
    let id: Vec<u16> = APP_ID.encode_utf16().chain(Some(0)).collect();
    unsafe { SetCurrentProcessExplicitAppUserModelID(PCWSTR(id.as_ptr()))? };
    Ok(())
}

fn escape_xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn play_sound(kind: &str) -> ResultType<()> {
    let file = match kind {
        "message" => "forlan-message.wav",
        "connection" => "forlan-connection.wav",
        "" => return Ok(()),
        _ => hbb_common::bail!("Unknown notification sound"),
    };
    let path = asset_path(file)?;
    if !path.is_file() {
        hbb_common::bail!("Notification sound is missing: {}", path.display());
    }
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe {
        PlaySoundW(
            wide.as_ptr(),
            std::ptr::null_mut(),
            0x0002_0000 | 0x0001 | 0x0002,
        )
    } == 0
    {
        hbb_common::bail!("Windows could not play the notification sound");
    }
    Ok(())
}

fn show_notification(notification: Notification) -> ResultType<()> {
    if notification.title.contains('\0') || notification.body.contains('\0') {
        hbb_common::bail!("Notification text contains an invalid character");
    }
    let initialized = unsafe { RoInitialize(1) };
    if initialized < 0 {
        hbb_common::bail!("Windows notification initialization failed: {initialized:#x}");
    }
    struct Apartment;
    impl Drop for Apartment {
        fn drop(&mut self) {
            unsafe { RoUninitialize() };
        }
    }
    let _apartment = Apartment;
    register_identity()?;
    let title = escape_xml(&notification.title.chars().take(120).collect::<String>());
    let body = escape_xml(&notification.body.chars().take(500).collect::<String>());
    let xml = XmlDocument::new()?;
    xml.LoadXml(&HSTRING::from(format!(
        "<toast duration=\"long\"><visual><binding template=\"ToastGeneric\"><text>{title}</text><text>{body}</text></binding></visual><audio silent=\"true\"/></toast>"
    )))?;
    let toast = ToastNotification::CreateToastNotification(&xml)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?;
    let expires = DateTime {
        UniversalTime: ((now.as_secs() + 11_644_473_600 + 15) * 10_000_000
            + u64::from(now.subsec_nanos() / 100)) as i64,
    };
    let reference: IReference<DateTime> = PropertyValue::CreateDateTime(expires)?.cast()?;
    toast.SetExpirationTime(&reference)?;
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_ID))?;
    notifier.Show(&toast)?;
    if let Err(error) = play_sound(&notification.sound) {
        hbb_common::throttled_log!(Duration::from_secs(30), warn, "Forlan notification sound failed: {error}");
    }
    std::thread::sleep(Duration::from_secs(15));
    notifier.Hide(&toast)?;
    Ok(())
}

#[no_mangle]
pub extern "C" fn forlan_tray_quit_main_window() {
    if crate::get_app_name() != "ForlanDestek" {
        return;
    }
    #[cfg(feature = "flutter")]
    if crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        "{\"name\":\"forlan-quit\"}".to_owned(),
    )
    .is_none()
    {
        log::info!("Forlan main window is already closed");
    }
}

pub fn request_tray_quit() -> bool {
    let result = (|| -> ResultType<()> {
        let window = unsafe { FindWindowW(w!("FLUTTER_RUNNER_WIN32_WINDOW"), w!("Forlan Destek"))? };
        let message_name: Vec<u16> = TRAY_QUIT_MESSAGE.encode_utf16().chain(Some(0)).collect();
        let message = unsafe { RegisterWindowMessageW(PCWSTR(message_name.as_ptr())) };
        if message == 0 {
            hbb_common::bail!("Could not register the Forlan exit message");
        }
        unsafe { PostMessageW(Some(window), message, WPARAM(0), LPARAM(0))? };
        Ok(())
    })();
    match result {
        Ok(()) => true,
        Err(error) => {
            log::warn!("Could not notify Forlan main window to quit: {error}");
            false
        }
    }
}

pub fn start_forlan_gui() {
    if crate::get_app_name() != "ForlanDestek" {
        return;
    }
    Config::set_option("stop-service".to_owned(), String::new());
    crate::ui_interface::refresh_options();
    handle_service_option("stop-service", "");
    if !crate::check_process("--tray", true) {
        if let Err(error) = crate::run_me(vec!["--tray"]) {
            log::warn!("Could not start the Forlan tray: {error}");
        }
    }
}

pub fn handle_service_option(key: &str, value: &str) -> bool {
    if crate::get_app_name() != "ForlanDestek" || key != "stop-service" {
        return false;
    }
    let stop = value == "Y";
    std::thread::spawn(move || {
        if !stop && crate::platform::is_installed() && !crate::platform::is_self_service_running() {
            if let Err(error) = start_installed_service() {
                log::warn!("Forlan Windows service could not be started: {error}");
            }
        }
        let mut options: HashMap<String, String> = crate::ipc::get_options();
        if stop {
            options.insert("stop-service".to_owned(), "Y".to_owned());
        } else {
            options.remove("stop-service");
        }
        if let Err(error) = crate::ipc::set_options(options) {
            log::warn!("Forlan service option could not be updated: {error}");
        }
        crate::ui_interface::refresh_options();
    });
    true
}

fn start_installed_service() -> ResultType<()> {
    use windows_service::{
        service::{ServiceAccess, ServiceState},
        service_manager::{ServiceManager, ServiceManagerAccess},
    };
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
    let service = manager.open_service(
        "ForlanDestek",
        ServiceAccess::START | ServiceAccess::QUERY_STATUS,
    )?;
    if !matches!(
        service.query_status()?.current_state,
        ServiceState::Running | ServiceState::StartPending
    ) {
        service.start::<&str>(&[])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn notification_text_is_escaped_for_windows_xml() {
        assert_eq!(
            super::escape_xml("A&B <test> \"\" '"),
            "A&amp;B &lt;test&gt; &quot;&quot; &apos;"
        );
    }
}
