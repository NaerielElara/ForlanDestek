use hbb_common::{serde_json, sodiumoxide::base64};
fn saved_connection_token(saved: &str, time: u64) -> Option<String> {
    let saved: serde_json::Value = serde_json::from_str(saved).ok()?;
    let token = saved["access_token"].as_str()?;
    let (header, rest) = token.split_once('.')?;
    let (payload, signature) = rest.split_once('.')?;
    if header.is_empty() || signature.is_empty() || signature.contains('.') { return None; }
    let payload = base64::decode(payload, base64::Variant::UrlSafeNoPadding).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&payload).ok()?;
    // This only selects a saved credential; the API still verifies its signature and rights.
    (claims["exp"].as_u64()? > time).then(|| token.to_owned())
}

#[cfg(test)]
mod saved_session_tests {
    
    pub fn expired_saved_access_uses_guest_until_the_refresh_finishes() {
        use hbb_common::sodiumoxide::base64;
        let payload = base64::encode(br#"{"exp":1000}"#, base64::Variant::UrlSafeNoPadding);
        let token = format!("header.{payload}.signature");
        let saved = serde_json::json!({"access_token":token,"refresh_token":"retained-refresh"}).to_string();
        assert_eq!(super::saved_connection_token(&saved, 999), Some(token));
        assert_eq!(super::saved_connection_token(&saved, 1000).unwrap_or_default(), "");
        assert_eq!(super::saved_connection_token(r#"{"access_token":"malformed","refresh_token":"retained-refresh"}"#, 999).unwrap_or_default(), "");
    }
}

fn main() { saved_session_tests::expired_saved_access_uses_guest_until_the_refresh_finishes(); println!("saved_access_expiry_regression=passed"); }
