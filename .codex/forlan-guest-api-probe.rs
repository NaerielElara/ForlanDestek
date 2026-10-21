use hbb_common::{serde_json, sodiumoxide::{base64, crypto::sign}};
use std::{error::Error,time::{SystemTime,UNIX_EPOCH}};
fn main() -> Result<(), Box<dyn Error>> { hbb_common::tokio::runtime::Builder::new_current_thread().enable_all().build()?.block_on(run()) }
async fn run() -> Result<(), Box<dyn Error>> {
    let root="https://95.70.196.174:24443";
    let certificate=reqwest::Certificate::from_pem(include_bytes!("../deploy/forlan-support/support-ca.crt"))?;
    let client=reqwest::Client::builder().use_rustls_tls().add_root_certificate(certificate).timeout(std::time::Duration::from_secs(12)).build()?;
    let id=SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let sid=format!("{:08x}-{:04x}-4{:03x}-8{:03x}-{:012x}",id as u32,(id>>32) as u16,(id>>48) as u16 & 0xfff,(id>>60) as u16 & 0xfff,(id>>72) as u64 & 0xffffffffffff);
    let device=(900000000+id%99999999).to_string();
    let request=serde_json::json!({"device_id":device,"session_id":sid,"peer_id":"654321"});
    let result=client.post(format!("{root}/api/connections/start")).body(request.to_string()).header("Content-Type","application/json").send().await?;
    println!("native_tls_status={}",result.status());
    if !result.status().is_success() { return Err("Native guest request failed".into()); }
    let result:serde_json::Value=serde_json::from_str(&result.text().await?)?;
    let encoded=result["permit"].as_str().ok_or("Permit missing")?;
    let (payload,signature)=encoded.split_once('.').ok_or("Permit format")?;
    let payload=base64::decode(payload,base64::Variant::Original).map_err(|_|"payload base64")?;
    let signature=base64::decode(signature,base64::Variant::Original).map_err(|_|"signature base64")?;
    let key:serde_json::Value=serde_json::from_str(&std::fs::read_to_string("deploy/forlan-support/policy-public-key.json")?)?;
    let key=base64::decode(key["public_key"].as_str().ok_or("Public key missing")?,base64::Variant::Original).map_err(|_|"key base64")?;
    let key=sign::PublicKey::from_slice(&key).ok_or("Public key length")?;
    let signature=sign::Signature::from_bytes(&signature).map_err(|_|"signature length")?;
    println!("native_signature_valid={}",sign::verify_detached(&signature,&payload,&key));
    let permit:serde_json::Value=serde_json::from_slice(&payload)?;
    println!("permit_matches_session={}",permit["session_id"]==request["session_id"] && permit["device_id"]==request["device_id"] && permit["peer_id"]==request["peer_id"] && permit["policy_session_id"]==request["session_id"]);
    println!("permit_future={}",permit["exp"].as_u64().ok_or("exp missing")?>SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs());
    println!("premium={}",permit["premium"]);
    let ended=client.post(format!("{root}/api/connections/{sid}/end")).send().await?;
    println!("lease_ended_status={}",ended.status());
    Ok(())
}


