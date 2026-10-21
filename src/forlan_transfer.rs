use base::{fs, message_proto::{cliprdr, Cliprdr, Message}};
use hbb_common::{anyhow::anyhow, tokio::time::Instant, ResultType, Stream};
use std::{collections::HashMap, sync::{atomic::{AtomicBool, Ordering}, Mutex}, time::Duration};

pub const FREE_TRANSFER_LIMIT: u64 = 30 * 1024 * 1024;

#[derive(Default)]
struct Usage {
    bytes: u64,
    published: Option<Instant>,
}

pub struct Quota {
    premium: AtomicBool,
    usage: Mutex<Usage>,
}

impl Quota {
    pub fn new(premium: bool) -> Self {
        Self { premium: AtomicBool::new(premium), usage: Mutex::new(Usage::default()) }
    }

    pub fn set_premium(&self, premium: bool) { self.premium.store(premium, Ordering::Release); }
    pub fn premium(&self) -> bool { self.premium.load(Ordering::Acquire) }
    pub fn used(&self) -> u64 { self.usage.lock().unwrap().bytes }
    pub fn limit(&self) -> u64 { if self.premium() { 0 } else { FREE_TRANSFER_LIMIT } }

    pub fn check_selection(&self, bytes: u64) -> ResultType<()> {
        if !self.premium() && bytes > FREE_TRANSFER_LIMIT.saturating_sub(self.used()) {
            return Err(anyhow!(self.message()));
        }
        Ok(())
    }

    pub fn consume(&self, bytes: u64) -> ResultType<bool> {
        if self.premium() || bytes == 0 { return Ok(false); }
        let mut usage = self.usage.lock().unwrap();
        if bytes > FREE_TRANSFER_LIMIT.saturating_sub(usage.bytes) {
            drop(usage);
            return Err(anyhow!(self.message()));
        }
        usage.bytes += bytes;
        let publish = usage.bytes == FREE_TRANSFER_LIMIT || usage.published.map_or(true, |time| time.elapsed() >= Duration::from_secs(1));
        if publish { usage.published = Some(Instant::now()); }
        Ok(publish)
    }

    pub fn message(&self) -> String {
        format!("Lisanssız dosya gönderim sınırı bu bağlantıda toplam 30 MB'dir. Kullanılan: {:.2} / 30 MB. Lisanslı bağlantılarda dosya boyutu sınırı yoktur.", self.used() as f64 / (1024.0 * 1024.0))
    }
}

#[derive(Default)]
pub struct ClipboardQuota {
    descriptor_format: Option<i32>,
    descriptor_requested: bool,
    requests: HashMap<i32, (i32, i32)>,
}

impl ClipboardQuota {
    pub fn incoming(&mut self, clip: &Cliprdr) {
        match clip.union.as_ref() {
            Some(cliprdr::Union::FormatDataRequest(request)) => {
                self.descriptor_requested = self.descriptor_format == Some(request.requested_format_id);
            }
            Some(cliprdr::Union::FileContentsRequest(request)) => {
                if self.requests.len() < 1024 || self.requests.contains_key(&request.stream_id) {
                    self.requests.insert(request.stream_id, (request.dw_flags, request.cb_requested));
                }
            }
            _ => {}
        }
    }

    pub fn outgoing(&mut self, message: &mut Message, quota: &Quota) -> ResultType<bool> {
        if quota.premium() { return Ok(false); }
        let Some(base::message_proto::message::Union::Cliprdr(clip)) = message.union.as_mut() else { return Ok(false); };
        match clip.union.as_mut() {
            Some(cliprdr::Union::FormatList(list)) => {
                self.descriptor_format = list.formats.iter().find(|format| format.format == "FileGroupDescriptorW").map(|format| format.id);
            }
            Some(cliprdr::Union::FormatDataResponse(response)) if self.descriptor_requested => {
                self.descriptor_requested = false;
                if response.msg_flags & 1 != 0 {
                    if let Some(bytes) = descriptor_size(&response.format_data) {
                        if let Err(error) = quota.check_selection(bytes) {
                            response.msg_flags = 2;
                            response.format_data = Default::default();
                            return Err(error);
                        }
                    }
                }
            }
            Some(cliprdr::Union::FileContentsResponse(response)) => {
                let flags = self.requests.remove(&response.stream_id);
                if response.msg_flags & 1 != 0 && !quota.premium() {
                    let result = match flags {
                        Some((1, _)) => Ok(false),
                        Some((2, requested)) => quota.consume(response.requested_data.len() as u64).map(|publish| publish || response.requested_data.len() < requested.max(0) as usize),
                        _ => Err(anyhow!("Dosya kopyalama isteği doğrulanamadı; aktarım durduruldu.")),
                    };
                    match result {
                        Ok(publish) => return Ok(publish),
                        Err(error) => {
                            response.msg_flags = 2;
                            response.requested_data = Default::default();
                            return Err(error);
                        }
                    }
                }
            }
            _ => {}
        }
        Ok(false)
    }
}

fn descriptor_size(data: &[u8]) -> Option<u64> {
    let count = u32::from_le_bytes(data.get(..4)?.try_into().ok()?) as usize;
    if count == 0 || count > data.len().saturating_sub(4) / 592 { return None; }
    let mut total = 0u64;
    for descriptor in data[4..].chunks_exact(592).take(count) {
        let attributes = u32::from_le_bytes(descriptor.get(36..40)?.try_into().ok()?);
        if attributes & 0x10 != 0 { continue; }
        let high = u32::from_le_bytes(descriptor.get(64..68)?.try_into().ok()?);
        let low = u32::from_le_bytes(descriptor.get(68..72)?.try_into().ok()?);
        total = total.checked_add(((high as u64) << 32) | low as u64)?;
    }
    Some(total)
}

pub async fn handle_read_jobs(jobs: &mut Vec<fs::TransferJob>, stream: &mut Stream, quota: &Quota) -> ResultType<(Vec<(i32, i32, String)>, bool)> {
    for job in jobs.iter_mut().filter(|job| !job.is_last_job) {
        match job.init_data_stream_for_cm().await {
            Ok(Some((last_modified, file_size))) => {
                let mut response = base::message_proto::FileResponse::new();
                response.set_digest(base::message_proto::FileTransferDigest {
                    id: job.id(), file_num: job.file_num(), last_modified, file_size, is_resume: job.is_resume, ..Default::default()
                });
                let mut message = Message::new();
                message.set_file_response(response);
                stream.send(&message).await?;
            }
            Ok(None) => {}
            Err(error) => stream.send(&fs::new_error(job.id(), error, job.file_num())).await?,
        }
    }
    let mut finished = None;
    let mut failures = Vec::new();
    let mut publish = false;
    if let Some(job) = jobs.iter_mut().find(|job| !job.is_last_job) {
        let before = job.finished_size();
        match job.read().await {
            Err(error) => stream.send(&fs::new_error(job.id(), error, job.file_num())).await?,
            Ok(Some(block)) => match quota.consume(job.finished_size().saturating_sub(before)) {
                Ok(updated) => {
                    publish = updated;
                    stream.send(&fs::new_block(block)).await?;
                }
                Err(error) => {
                    let message = error.to_string();
                    stream.send(&fs::new_error(job.id(), &message, job.file_num())).await?;
                    failures.push((job.id(), job.file_num(), message));
                    finished = Some(job.id());
                    publish = true;
                }
            },
            Ok(None) if job.job_completed() => {
                publish = true;
                finished = Some(job.id());
                match job.job_error() {
                    Some(error) => stream.send(&fs::new_error(job.id(), error, job.file_num())).await?,
                    None => stream.send(&fs::new_done(job.id(), job.file_num())).await?,
                }
            }
            Ok(None) => {}
        }
    }
    if let Some(id) = finished { fs::remove_job(id, jobs); }
    Ok((failures, publish))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn file_manager_and_clipboard_share_the_same_connection_budget() {
        let remote = Arc::new(Quota::new(false));
        let file_manager = remote.clone();
        remote.consume(10 * 1024 * 1024).unwrap();
        file_manager.consume(20 * 1024 * 1024).unwrap();
        assert!(remote.consume(1).is_err());
        assert!(file_manager.check_selection(1).is_err());
        assert_eq!(remote.used(), FREE_TRANSFER_LIMIT);
    }

    #[test]
    fn licensed_initiator_has_no_size_limit() {
        let quota = Quota::new(true);
        assert!(quota.check_selection(u64::MAX).is_ok());
        assert!(quota.consume(u64::MAX).is_ok());
        assert_eq!(quota.limit(), 0);
    }

    #[test]
    fn clipboard_size_metadata_is_excluded_and_excess_range_fails_cleanly() {
        let quota = Quota::new(false);
        quota.consume(FREE_TRANSFER_LIMIT - 2).unwrap();
        let mut clipboard = ClipboardQuota::default();
        for (flags, bytes, expected) in [(1, 8, true), (2, 3, false)] {
            let mut incoming = Cliprdr::new();
            incoming.set_file_contents_request(base::message_proto::CliprdrFileContentsRequest { stream_id: 7, dw_flags: flags, ..Default::default() });
            clipboard.incoming(&incoming);
            let mut outgoing = crate::clipboard_file::clip_2_msg(clipboard::ClipboardFile::FileContentsResponse { msg_flags: 1, stream_id: 7, requested_data: vec![0; bytes] });
            assert_eq!(clipboard.outgoing(&mut outgoing, &quota).is_ok(), expected);
            if !expected {
                let Some(base::message_proto::message::Union::Cliprdr(clip)) = outgoing.union else { panic!("Missing clipboard reply") };
                let Some(cliprdr::Union::FileContentsResponse(response)) = clip.union else { panic!("Missing file reply") };
                assert_eq!(response.msg_flags, 2);
                assert!(response.requested_data.is_empty());
            }
        }
        assert_eq!(quota.used(), FREE_TRANSFER_LIMIT - 2);
    }
}
