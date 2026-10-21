#[path = "../src/platform/windows/forlan_session_store.rs"]
mod session_store;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let session = br#"{"access_token":"test-access-only","refresh_token":"test-refresh-only"}"#;
    let encrypted = session_store::protect(session)?;
    assert!(!encrypted.windows(session.len()).any(|part| part == session));
    let path = std::env::temp_dir().join(format!("forlan-session-persistence-171-{}.bin", std::process::id()));
    std::fs::write(&path, encrypted)?;
    let saved = std::fs::read(&path)?;
    std::fs::remove_file(&path)?;
    assert_eq!(session_store::unprotect(&saved)?, session);
    println!("dpapi_session_disk_round_trip=passed");
    Ok(())
}
