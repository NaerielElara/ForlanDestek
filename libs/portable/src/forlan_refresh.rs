use std::{
    ffi::OsString,
    os::windows::{ffi::OsStringExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
};
use windows::{
    core::PWSTR,
    Win32::{
        Foundation::CloseHandle,
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
                TH32CS_SNAPPROCESS,
            },
            SystemInformation::GetSystemDirectoryW,
            Threading::{
                OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
                PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
    },
};

#[path = "../../../src/platform/windows/forlan_reset_files.rs"]
#[allow(dead_code)]
mod files;

pub const LAUNCHER_ENV: &str = "FORLAN_PORTABLE_LAUNCHER";

pub fn is_forlan(exe: &str) -> bool {
    Path::new(exe)
        .file_stem()
        .and_then(|v| v.to_str())
        .map(|v| v.eq_ignore_ascii_case("ForlanDestek"))
        .unwrap_or(false)
}

pub fn prepare(exe: &str, args: &[String]) -> Result<bool, String> {
    if !is_forlan(exe) {
        return Ok(false);
    }
    let local = dirs::data_local_dir()
        .ok_or_else(|| "Local application data directory is unavailable".to_owned())?;
    files::validate_path(&local).map_err(|e| e.to_string())?;
    let complete = files::reset_complete(&local).map_err(|e| e.to_string())?;
    let refresh = args
        .first()
        .map(|arg| arg == "--update")
        .unwrap_or(!complete);
    if refresh {
        let extraction = local.join("forlandestek");
        files::validate_tree(&extraction).map_err(|e| e.to_string())?;
        let paths =
            files::owned_tree_paths(&extraction, &local, "Local").map_err(|e| e.to_string())?;
        for pid in extraction_processes(&paths)? {
            let output = Command::new(system_taskkill()?)
                .args(["/F", "/PID", &pid.to_string()])
                .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
                .output()
                .map_err(|e| format!("Could not stop previous Forlan Destek: {e}"))?;
            if !output.status.success() && output.status.code() != Some(128) {
                return Err(format!(
                    "Could not stop previous Forlan Destek: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ));
            }
        }
    }
    Ok(refresh)
}

fn system_taskkill() -> Result<PathBuf, String> {
    let mut buffer = [0u16; 260];
    let length = unsafe { GetSystemDirectoryW(Some(&mut buffer)) } as usize;
    if length == 0 || length >= buffer.len() {
        return Err("Windows system directory is unavailable".to_owned());
    }
    Ok(PathBuf::from(OsString::from_wide(&buffer[..length])).join("taskkill.exe"))
}

fn extraction_processes(extractions: &[PathBuf]) -> Result<Vec<u32>, String> {
    let prefixes: Vec<_> = extractions
        .iter()
        .map(|path| {
            format!(
                "{}\\",
                path.to_string_lossy()
                    .trim_start_matches(r"\\?\")
                    .to_ascii_lowercase()
            )
        })
        .collect();
    let snapshot =
        unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }.map_err(|e| e.to_string())?;
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    let mut processes = Vec::new();
    let mut found = unsafe { Process32FirstW(snapshot, &mut entry) }.is_ok();
    while found {
        if entry.th32ProcessID != std::process::id() {
            if let Ok(process) = unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION,
                    false,
                    entry.th32ProcessID,
                )
            } {
                let mut buffer = vec![0u16; 32768];
                let mut size = buffer.len() as u32;
                if unsafe {
                    QueryFullProcessImageNameW(
                        process,
                        PROCESS_NAME_WIN32,
                        PWSTR(buffer.as_mut_ptr()),
                        &mut size,
                    )
                }
                .is_ok()
                {
                    let path =
                        String::from_utf16_lossy(&buffer[..size as usize]).to_ascii_lowercase();
                    if prefixes.iter().any(|prefix| path.starts_with(prefix)) {
                        processes.push(entry.th32ProcessID);
                    }
                }
                let _ = unsafe { CloseHandle(process) };
            }
        }
        found = unsafe { Process32NextW(snapshot, &mut entry) }.is_ok();
    }
    let _ = unsafe { CloseHandle(snapshot) };
    Ok(processes)
}

pub fn clear_extraction(dir: &Path) -> Result<(), String> {
    let local = dirs::data_local_dir()
        .ok_or_else(|| "Local application data directory is unavailable".to_owned())?;
    if dir != local.join("forlandestek") {
        return Err("Unexpected Forlan extraction directory".to_owned());
    }
    files::remove_forlan_tree(&local, "forlandestek", &local, "Local")
        .map_err(|e| format!("Could not refresh Forlan package: {e}"))
}
