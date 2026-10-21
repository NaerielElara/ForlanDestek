use std::{io, slice};
use windows::{
    core::w,
    Win32::{
        Foundation::{HLOCAL, LocalFree},
        Security::Cryptography::{
            CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB,
            CRYPTPROTECT_UI_FORBIDDEN,
        },
    },
};

pub fn protect(value: &[u8]) -> io::Result<Vec<u8>> {
    transform(value, true)
}

pub fn unprotect(value: &[u8]) -> io::Result<Vec<u8>> {
    transform(value, false)
}

fn transform(value: &[u8], encrypt: bool) -> io::Result<Vec<u8>> {
    if value.is_empty() || value.len() > 65_536 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Geçersiz oturum kaydı"));
    }
    let input = CRYPT_INTEGER_BLOB { cbData: value.len() as u32, pbData: value.as_ptr() as *mut u8 };
    let mut output = CRYPT_INTEGER_BLOB::default();
    unsafe {
        let result = if encrypt {
            CryptProtectData(&input, w!("Forlan Destek oturumu"), None, None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut output)
        } else {
            CryptUnprotectData(&input, None, None, None, None, CRYPTPROTECT_UI_FORBIDDEN, &mut output)
        };
        result.map_err(io::Error::other)?;
        let bytes = if output.pbData.is_null() || output.cbData == 0 {
            Err(io::Error::new(io::ErrorKind::InvalidData, "Oturum kaydı çözülemedi"))
        } else {
            Ok(slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec())
        };
        if !output.pbData.is_null() {
            if !LocalFree(Some(HLOCAL(output.pbData.cast()))).0.is_null() {
                return Err(io::Error::last_os_error());
            }
        }
        bytes
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn session_survives_disk_round_trip_without_plaintext_credentials() {
        let session = br#"{"access_token":"test-access","refresh_token":"test-refresh"}"#;
        let protected = super::protect(session).unwrap();
        assert!(!protected.windows(session.len()).any(|value| value == session));
        let path = std::env::temp_dir().join(format!("forlan-session-test-{}.bin", std::process::id()));
        std::fs::write(&path, &protected).unwrap();
        let saved = std::fs::read(&path).unwrap();
        std::fs::remove_file(path).unwrap();
        assert_eq!(super::unprotect(&saved).unwrap(), session);
    }
}
