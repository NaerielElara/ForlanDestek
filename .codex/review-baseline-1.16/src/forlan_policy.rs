use crate::client::Data;
use hbb_common::{
    anyhow::{anyhow, Context},
    config::Config,
    sodiumoxide::{base64, crypto::sign},
    tokio::{self, sync::{mpsc, oneshot}},
    ResultType,
};
use serde::{Deserialize, Serialize};
use std::{sync::Mutex, time::{Duration, SystemTime, UNIX_EPOCH}};

static SUPPORT_TOKEN: Mutex<String> = Mutex::new(String::new());

pub fn handle_local_option(key: &str, value: &str) -> bool {
    if crate::get_app_name() != "ForlanDestek" || key != "forlan-support-session" {
        return false;
    }
    *SUPPORT_TOKEN.lock().unwrap() = value.to_owned();
    true
}

#[derive(Clone, Serialize)]
struct LeaseRequest {
    device_id: String,
    session_id: String,
    peer_id: String,
}

#[derive(Deserialize)]
struct Permit {
    session_id: String,
    device_id: String,
    peer_id: String,
    exp: u64,
    connection_expires: u64,
    premium: bool,
}

#[derive(Deserialize)]
struct LeaseResponse {
    permit: String,
}

#[derive(Debug)]
struct PolicyDenied(String);
impl std::fmt::Display for PolicyDenied {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(&self.0) }
}
impl std::error::Error for PolicyDenied {}

pub struct Lease {
    request: LeaseRequest,
    client: reqwest::Client,
    cancel: Option<oneshot::Sender<()>>,
}

fn endpoint() -> &'static str {
    option_env!("FORLAN_SUPPORT_API_URL").unwrap_or("https://95.70.196.174:24443")
}

fn now() -> ResultType<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

fn verify_permit(encoded: &str, request: &LeaseRequest) -> ResultType<Permit> {
    let (payload, signature) = encoded.split_once('.').context("Bağlantı izni eksik")?;
    let payload = base64::decode(payload, base64::Variant::Original).map_err(|_| anyhow!("Bağlantı izni okunamadı"))?;
    let signature = base64::decode(signature, base64::Variant::Original).map_err(|_| anyhow!("Bağlantı imzası okunamadı"))?;
    let public_key = option_env!("FORLAN_POLICY_PUBLIC_KEY").context("Lisans doğrulama anahtarı bu derlemede yok")?;
    let public_key = base64::decode(public_key.trim(), base64::Variant::Original).map_err(|_| anyhow!("Lisans doğrulama anahtarı geçersiz"))?;
    let public_key = sign::PublicKey::from_slice(&public_key).context("Lisans doğrulama anahtarı geçersiz")?;
    let signature = sign::Signature::from_bytes(&signature).map_err(|_| anyhow!("Bağlantı imzası geçersiz"))?;
    if !sign::verify_detached(&signature, &payload, &public_key) {
        hbb_common::bail!("Sunucunun bağlantı imzası doğrulanamadı");
    }
    let permit: Permit = serde_json::from_slice(&payload)?;
    if permit.session_id != request.session_id || permit.device_id != request.device_id || permit.peer_id != request.peer_id || permit.exp <= now()? {
        hbb_common::bail!("Bağlantı izni bu oturuma ait değil veya süresi dolmuş");
    }
    Ok(permit)
}

async fn refresh(client: &reqwest::Client, request: &LeaseRequest) -> ResultType<Permit> {
    let token = SUPPORT_TOKEN.lock().unwrap().clone();
    let mut call = client.post(format!("{}/api/connections/start", endpoint())).json(request);
    if !token.is_empty() {
        call = call.bearer_auth(token);
    }
    let response = call.send().await?;
    if !response.status().is_success() {
        let body: serde_json::Value = response.json().await?;
        let detail = &body["detail"];
        if let Some(wait) = detail["retry_after"].as_u64() {
            crate::flutter::push_global_event(crate::flutter::APP_TYPE_MAIN, serde_json::json!({"name":"forlan-policy-state","waiting_until":now()?+wait}).to_string());
            return Err(anyhow!(PolicyDenied(format!("Lisanssız kullanım sınırı. Yeniden bağlantı için {} saniye bekleyin. Lisanslı hesaplarda bu sınır uygulanmaz.", wait))));
        }
        return Err(anyhow!(PolicyDenied(detail.as_str().unwrap_or("Lisans sunucusu bağlantıya izin vermedi").to_owned())));
    }
    let result: LeaseResponse = response.json().await?;
    verify_permit(&result.permit, request)
}

fn policy_message(message: &str) {
    crate::flutter::push_global_event(crate::flutter::APP_TYPE_MAIN, serde_json::json!({"name":"forlan-policy-message","message":message}).to_string());
}

pub async fn begin(peer_id: String, sender: mpsc::UnboundedSender<Data>) -> ResultType<Option<Lease>> {
    if crate::get_app_name() != "ForlanDestek" {
        return Ok(None);
    }
    let certificate = reqwest::Certificate::from_pem(include_bytes!("../deploy/forlan-support/support-ca.crt"))?;
    let client = reqwest::Client::builder().use_rustls_tls().add_root_certificate(certificate).timeout(Duration::from_secs(12)).build()?;
    let request = LeaseRequest { device_id: Config::get_id(), session_id: uuid::Uuid::new_v4().to_string(), peer_id };
    let permit = refresh(&client, &request).await?;
    crate::flutter::push_global_event(crate::flutter::APP_TYPE_MAIN, serde_json::json!({"name":"forlan-policy-state","session_id":request.session_id,"premium":permit.premium,"expires":permit.connection_expires,"active":true}).to_string());
    if !permit.premium {
        policy_message("Lisanssız bağlantı: en fazla 5 dakika. Süre dolduğunda 1 dakika ara verilir.");
    }
    let (cancel, mut cancellation) = oneshot::channel();
    let monitor_client = client.clone();
    let monitor_request = request.clone();
    tokio::spawn(async move {
        let mut permit = permit;
        let mut next_refresh = tokio::time::Instant::now() + Duration::from_secs(30);
        loop {
            tokio::select! {
                _ = &mut cancellation => break,
                _ = tokio::time::sleep(Duration::from_secs(1)) => {
                    match now() {
                        Ok(time) if time >= permit.exp || time >= permit.connection_expires => {
                            policy_message(if !permit.premium && time >= permit.connection_expires {"5 dakikalık kullanım süresi doldu. 1 dakika sonra tekrar bağlanabilirsiniz."} else {"Lisans sunucusuyla doğrulama yenilenemedi; bağlantı kapatıldı."});
                            if sender.send(Data::Close).is_err() { break; }
                            break;
                        }
                        Err(_) => { let _ = sender.send(Data::Close); break; }
                        _ => {}
                    }
                    if tokio::time::Instant::now() >= next_refresh {
                        let remaining = permit.exp.min(permit.connection_expires).saturating_sub(now().unwrap_or(u64::MAX)).max(1).min(12);
                        match tokio::time::timeout(Duration::from_secs(remaining), refresh(&monitor_client, &monitor_request)).await {
                            Ok(Ok(updated)) => permit = updated,
                            Ok(Err(error)) => {
                                if error.is::<PolicyDenied>() {
                                    policy_message(&error.to_string());
                                    if sender.send(Data::Close).is_err() { break; }
                                    break;
                                }
                                hbb_common::throttled_log!(Duration::from_secs(30), warn, "Forlan connection policy refresh failed: {error}");
                            }
                            Err(_) => hbb_common::throttled_log!(Duration::from_secs(30), warn, "Forlan connection policy refresh timed out"),
                        }
                        next_refresh = tokio::time::Instant::now() + Duration::from_secs(30);
                    }
                }
            }
        }
    });
    Ok(Some(Lease { request, client, cancel: Some(cancel) }))
}

impl Lease {
    pub async fn finish(mut self) {
        if let Some(cancel) = self.cancel.take() { let _ = cancel.send(()); }
        crate::flutter::push_global_event(crate::flutter::APP_TYPE_MAIN, serde_json::json!({"name":"forlan-policy-state","session_id":self.request.session_id,"active":false}).to_string());
        if let Err(error) = self.client.post(format!("{}/api/connections/{}/end",endpoint(),self.request.session_id)).send().await {
            hbb_common::throttled_log!(Duration::from_secs(30), warn, "Forlan connection lease end failed: {error}");
        }
    }
}
