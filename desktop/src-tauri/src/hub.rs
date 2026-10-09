//! The hub: listens for phones, runs the handshake and the sealed session, and
//! carries every feature between the phone and this computer.
//!
//! Same contract as the Mac's ConnectionManager (docs/PROTOCOL.md): the phone
//! dials in and is the initiator; before the session key exists only the
//! handshake is accepted, and anything else drops the connection.

use crate::crypto::{self, read_frame, write_frame, Transport, DIR_RESPONDER, SALT_LEN};
use crate::proto::{self, envelope::Payload, Envelope};
use crate::store::{self, Device, Store};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use prost::Message;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tauri_plugin_notification::NotificationExt;
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Notify};
use tokio::time::timeout;
use x25519_dalek::{PublicKey, StaticSecret};

pub const PORT: u16 = 18920;
const CHUNK: usize = 64 * 1024;
/// Anything on the LAN can open the port; a handshake that doesn't arrive
/// promptly is a stranger, not a slow phone.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Three missed 10 s pings. A phone that leaves the Wi-Fi never closes its socket.
const PEER_TIMEOUT: Duration = Duration::from_secs(30);
/// ponytail: fixed cap on open sockets so a flood of strangers can't pin
/// memory; per-address limits if this is ever exposed beyond a home LAN.
const MAX_CONNECTIONS: usize = 16;

pub struct Hub {
    app: AppHandle,
    secret: StaticSecret,
    public: [u8; 32],
    pub name: String,
    store: Store,
    /// The token in the QR on screen. Some only while pairing.
    pairing_token: Mutex<Option<String>>,
    /// Device id → its live, key-confirmed session.
    sessions: Mutex<HashMap<String, Session>>,
    /// Device id → what the phone last reported.
    live: Mutex<HashMap<String, Live>>,
    /// Notification id → the phone it came from, so a reply goes back there.
    notif_owner: Mutex<HashMap<String, String>>,
    /// Outgoing transfer id → cancelled by the phone.
    outgoing: Mutex<HashMap<String, Arc<AtomicBool>>>,
    clip: Mutex<ClipState>,
    /// ClipboardUpdate.origin_id for clips copied here.
    origin_id: String,
    connections: AtomicUsize,
    mdns: Mutex<Option<mdns_sd::ServiceDaemon>>,
    error: Mutex<Option<String>>,
}

#[derive(Clone)]
struct Session {
    tx: mpsc::Sender<Envelope>,
    kick: Arc<Notify>,
}

#[derive(Default)]
struct Live {
    battery: Option<BatteryView>,
    playing: Option<PlayingView>,
}

#[derive(Default)]
struct ClipState {
    last_seen: String,
    /// Text we just wrote from a phone; the watcher must not send it back.
    applied_remote: String,
}

#[derive(Serialize, Clone)]
pub struct Snapshot {
    name: String,
    address: String,
    phones: Vec<PhoneView>,
    error: Option<String>,
}

#[derive(Serialize, Clone)]
struct PhoneView {
    id: String,
    name: String,
    connected: bool,
    battery: Option<BatteryView>,
    playing: Option<PlayingView>,
}

#[derive(Serialize, Clone)]
struct BatteryView {
    percent: u32,
    charging: bool,
    low: bool,
}

#[derive(Serialize, Clone)]
struct PlayingView {
    app: String,
    title: String,
    artist: String,
    playing: bool,
}

#[derive(Serialize, Clone)]
struct NotifView {
    id: String,
    device: String,
    app: String,
    title: String,
    text: String,
    time: i64,
    can_reply: bool,
    is_call: bool,
}

#[derive(Serialize, Clone)]
struct TransferView {
    id: String,
    name: String,
    incoming: bool,
    done: u64,
    total: u64,
    finished: bool,
    error: Option<String>,
}

#[derive(Serialize)]
pub struct PairingView {
    svg: String,
    code: String,
    address: String,
}

fn env(payload: Payload) -> Envelope {
    Envelope { id: 0, payload: Some(payload) }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The LAN address phones should dial — the interface the default route uses.
/// Connecting a UDP socket sends nothing; it only picks the route.
pub fn local_ip() -> String {
    std::net::UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| s.connect("8.8.8.8:80").map(|_| s))
        .and_then(|s| s.local_addr())
        .map(|a| a.ip().to_string())
        .unwrap_or_default()
}

impl Hub {
    pub fn new(app: AppHandle) -> Result<Arc<Self>, String> {
        let store = Store::open();
        let secret = store.identity()?;
        // "DESKTOP-1A2B" on Windows; macOS and some Linux add ".local" or a
        // domain, which would double up in the mDNS host name. Colons separate
        // QR fields, so they cannot appear inside one.
        let host = gethostname::gethostname().to_string_lossy().into_owned();
        let name = host.split('.').next().filter(|n| !n.is_empty()).unwrap_or("Computer").replace(':', "-");
        Ok(Arc::new(Self {
            app,
            public: store::public_key(&secret),
            secret,
            name,
            store,
            pairing_token: Mutex::new(None),
            sessions: Mutex::default(),
            live: Mutex::default(),
            notif_owner: Mutex::default(),
            outgoing: Mutex::default(),
            clip: Mutex::default(),
            origin_id: uuid::Uuid::new_v4().to_string(),
            connections: AtomicUsize::new(0),
            mdns: Mutex::new(None),
            error: Mutex::new(None),
        }))
    }

    // ─── UI state ────────────────────────────────────────────────────────────

    pub fn snapshot(&self) -> Snapshot {
        let sessions = self.sessions.lock().unwrap();
        let live = self.live.lock().unwrap();
        Snapshot {
            name: self.name.clone(),
            address: local_ip(),
            phones: self
                .store
                .devices()
                .into_iter()
                .map(|d| PhoneView {
                    connected: sessions.contains_key(&d.id),
                    battery: live.get(&d.id).and_then(|l| l.battery.clone()),
                    playing: live.get(&d.id).and_then(|l| l.playing.clone()),
                    id: d.id,
                    name: d.name,
                })
                .collect(),
            error: self.error.lock().unwrap().clone(),
        }
    }

    fn changed(&self) {
        let _ = self.app.emit("state", self.snapshot());
    }

    fn fail(&self, message: String) {
        eprintln!("{message}");
        *self.error.lock().unwrap() = Some(message);
        self.changed();
    }

    // ─── Listening ───────────────────────────────────────────────────────────

    pub async fn run(self: Arc<Self>) {
        let listener = match TcpListener::bind(("0.0.0.0", PORT)).await {
            Ok(l) => l,
            Err(e) => return self.fail(format!("Can't listen on port {PORT} — is Bridg already running? ({e})")),
        };
        self.advertise();
        loop {
            let Ok((stream, _)) = listener.accept().await else { continue };
            if self.connections.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
                self.connections.fetch_sub(1, Ordering::SeqCst);
                continue;
            }
            let hub = self.clone();
            tokio::spawn(async move {
                hub.clone().serve(stream).await;
                hub.connections.fetch_sub(1, Ordering::SeqCst);
            });
        }
    }

    /// Bonjour, same service and TXT keys as the Mac. Many networks drop
    /// multicast, which is why the QR also carries the address.
    fn advertise(&self) {
        let ip = local_ip();
        let host = format!("{}.local.", self.name.replace(' ', "-"));
        let tag = crypto::hub_tag(&self.public);
        let props = [("name", self.name.as_str()), ("id", tag.as_str())];
        let result = mdns_sd::ServiceDaemon::new().and_then(|daemon| {
            let info = mdns_sd::ServiceInfo::new("_bridg._tcp.local.", &format!("Bridg-{}", self.name), &host, ip.as_str(), PORT, &props[..])?
                .enable_addr_auto();
            daemon.register(info)?;
            Ok(daemon)
        });
        match result {
            Ok(daemon) => *self.mdns.lock().unwrap() = Some(daemon),
            Err(e) => eprintln!("Bonjour unavailable, phones must use the QR address: {e}"),
        }
    }

    // ─── Pairing ─────────────────────────────────────────────────────────────

    pub fn start_pairing(&self) -> Result<PairingView, String> {
        let token = B64.encode(rand::random::<[u8; 16]>());
        let address = local_ip();
        let code = format!("bridg://pair/{}:{}:{}:{}", B64.encode(self.public), token, address, self.name);
        let svg = qrcode::QrCode::new(code.as_bytes())
            .map_err(|e| e.to_string())?
            .render::<qrcode::render::svg::Color>()
            .min_dimensions(240, 240)
            .build();
        *self.pairing_token.lock().unwrap() = Some(token);
        Ok(PairingView { svg, code, address })
    }

    pub fn cancel_pairing(&self) {
        *self.pairing_token.lock().unwrap() = None;
    }

    pub fn unpair(&self, id: &str) {
        self.store.remove(id);
        if let Some(session) = self.sessions.lock().unwrap().remove(id) {
            session.kick.notify_one();
        }
        self.changed();
    }

    fn agree(&self, peer: &[u8], initiator_salt: &[u8]) -> Option<([u8; 32], [u8; SALT_LEN])> {
        if initiator_salt.len() != SALT_LEN {
            eprintln!("Handshake carried no session salt — refusing. Update the phone app.");
            return None;
        }
        let peer: [u8; 32] = peer.try_into().ok()?;
        let shared = self.secret.diffie_hellman(&PublicKey::from(peer));
        // A low-order point gives an all-zero secret anyone could compute.
        if !shared.was_contributory() {
            return None;
        }
        let ours = crypto::random_salt();
        Some((crypto::session_key(shared.as_bytes(), initiator_salt, &ours), ours))
    }

    /// QR pairing: the token proves the phone saw this screen.
    fn accept_pairing(&self, req: proto::PairRequest) -> Option<(Device, [u8; 32], Envelope)> {
        let expected = self.pairing_token.lock().unwrap().clone()?;
        if req.pairing_token != expected {
            eprintln!("Pairing token mismatch — ignoring");
            return None;
        }
        let (key, salt) = self.agree(&req.sender_pubkey, &req.session_salt)?;
        let device = self.store.add(&req.device_name, &req.sender_pubkey);
        *self.pairing_token.lock().unwrap() = None;
        let _ = self.app.emit("paired", device.name.clone());
        let reply = env(Payload::PairResponse(proto::PairResponse {
            responder_pubkey: self.public.to_vec(),
            device_name: self.name.clone(),
            session_salt: salt.to_vec(),
            accepted: true,
        }));
        Some((device, key, reply))
    }

    /// Reconnect. The key hash is public, so this authenticates nothing by
    /// itself: only a holder of the phone's private key can derive the session
    /// key, and the first sealed frame is what proves it.
    fn accept_resume(&self, res: proto::PairResume) -> Option<(Device, [u8; 32], Envelope)> {
        let device = self.store.devices().into_iter().find(|d| {
            B64.decode(&d.public_key).map(|k| Sha256::digest(k).as_slice() == res.device_pubkey_hash.as_slice()).unwrap_or(false)
        })?;
        let (key, salt) = self.agree(&B64.decode(&device.public_key).ok()?, &res.session_salt)?;
        let reply = env(Payload::PairResumeAck(proto::PairResumeAck { session_salt: salt.to_vec(), accepted: true }));
        Some((device, key, reply))
    }

    // ─── One connection ──────────────────────────────────────────────────────

    async fn serve(self: Arc<Self>, stream: TcpStream) {
        let _ = stream.set_nodelay(true);
        let (mut rd, mut wr) = stream.into_split();

        // The first frame must be the handshake, in the clear. Anything else is
        // someone who never paired talking to an open port.
        let Ok(Ok(Some(first))) = timeout(HANDSHAKE_TIMEOUT, read_frame(&mut rd)).await else { return };
        let accepted = match Envelope::decode(&first[..]).ok().and_then(|e| e.payload) {
            Some(Payload::PairRequest(req)) => self.accept_pairing(req),
            Some(Payload::PairResume(res)) => self.accept_resume(res),
            _ => None,
        };
        let Some((device, key, reply)) = accepted else { return };
        // The reply is the last plaintext frame; it carries our salt half.
        if write_frame(&mut wr, &reply.encode_to_vec()).await.is_err() {
            return;
        }

        let mut opener = Transport::new(&key, DIR_RESPONDER);
        let mut sealer = Transport::new(&key, DIR_RESPONDER);
        let (tx, mut rx) = mpsc::channel::<Envelope>(256);
        let writer = tokio::spawn(async move {
            while let Some(e) = rx.recv().await {
                if write_frame(&mut wr, &sealer.seal(&e.encode_to_vec())).await.is_err() {
                    break;
                }
            }
        });
        let pinger = {
            let tx = tx.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(10)).await;
                    let ping = env(Payload::Ping(proto::Ping { timestamp: now_ms() }));
                    if tx.send(ping).await.is_err() {
                        break;
                    }
                }
            })
        };

        let kick = Arc::new(Notify::new());
        let mut confirmed = false;
        let mut incoming = Incoming::default();
        loop {
            // Only the read is raced against `kick`, and a kick ends the
            // session anyway — read_exact is not safe to cancel and resume.
            let frame = tokio::select! {
                f = timeout(PEER_TIMEOUT, read_frame(&mut rd)) => f,
                _ = kick.notified() => break,
            };
            let Ok(Ok(Some(frame))) = frame else { break };
            // Replay, forgery or a wrong key: none improve with the next frame.
            let Some(plain) = opener.open(&frame) else { break };
            if !confirmed {
                // The phone has proved it holds the key; only now may it take
                // over from an older session for the same device.
                confirmed = true;
                self.register(&device.id, Session { tx: tx.clone(), kick: kick.clone() });
            }
            if let Ok(e) = Envelope::decode(&plain[..]) {
                self.handle(&device, e, &tx, &mut incoming);
            }
        }

        pinger.abort();
        writer.abort();
        incoming.abandon();
        self.unregister(&device.id, &kick);
    }

    fn register(&self, id: &str, session: Session) {
        eprintln!("Phone connected: {id}");
        if let Some(old) = self.sessions.lock().unwrap().insert(id.to_string(), session) {
            old.kick.notify_one();
        }
        self.changed();
    }

    fn unregister(&self, id: &str, kick: &Arc<Notify>) {
        let mut sessions = self.sessions.lock().unwrap();
        if sessions.get(id).is_some_and(|s| Arc::ptr_eq(&s.kick, kick)) {
            sessions.remove(id);
            drop(sessions);
            eprintln!("Phone disconnected: {id}");
            self.live.lock().unwrap().remove(id);
            self.changed();
        }
    }

    fn send_to(&self, device: &str, e: Envelope) -> bool {
        let tx = self.sessions.lock().unwrap().get(device).map(|s| s.tx.clone());
        tx.is_some_and(|tx| tx.try_send(e).is_ok())
    }

    fn broadcast_except(&self, except: Option<&str>, e: &Envelope) {
        for (id, s) in self.sessions.lock().unwrap().iter() {
            if Some(id.as_str()) != except {
                let _ = s.tx.try_send(e.clone());
            }
        }
    }

    // ─── Messages from a phone ───────────────────────────────────────────────

    fn handle(&self, device: &Device, e: Envelope, tx: &mpsc::Sender<Envelope>, incoming: &mut Incoming) {
        match e.payload {
            Some(Payload::Ping(p)) => {
                let _ = tx.try_send(env(Payload::Pong(proto::Pong { timestamp: now_ms(), ping_timestamp: p.timestamp })));
            }
            Some(Payload::Notification(n)) => self.show_notification(device, n),
            Some(Payload::NotifDismiss(d)) => {
                self.notif_owner.lock().unwrap().remove(&d.id);
                let _ = self.app.emit("notification-removed", d.id);
            }
            Some(Payload::Clipboard(c)) => {
                if c.origin_id == self.origin_id || c.content.is_empty() {
                    return; // ponytail: text only; images when someone asks
                }
                self.apply_clipboard(&c.content);
                // Copy on one phone, paste on the other: pass it on, origin intact.
                self.broadcast_except(Some(&device.id), &env(Payload::Clipboard(c)));
            }
            Some(Payload::DeviceStatus(s)) => {
                self.live.lock().unwrap().entry(device.id.clone()).or_default().battery =
                    Some(BatteryView { percent: s.battery_percent, charging: s.charging, low: s.battery_low });
                self.changed();
            }
            Some(Payload::MediaState(m)) => {
                self.live.lock().unwrap().entry(device.id.clone()).or_default().playing = m.active.then(|| PlayingView {
                    app: m.app_label,
                    title: m.title,
                    artist: m.artist,
                    playing: m.playing,
                });
                self.changed();
            }
            Some(Payload::FileStart(s)) => {
                if let Some(ack) = incoming.start(s, &self.app) {
                    let _ = tx.try_send(env(Payload::FileAck(ack)));
                }
            }
            Some(Payload::FileChunk(c)) => {
                if let Some(ack) = incoming.chunk(c, &self.app) {
                    let _ = tx.try_send(env(Payload::FileAck(ack)));
                }
            }
            Some(Payload::FileCancel(c)) => incoming.cancel(&c.transfer_id, &self.app),
            Some(Payload::FileAck(a)) => self.outgoing_ack(a),
            // Mirroring is a later step; the phone streams to every computer,
            // so frames arriving here are expected and dropped.
            _ => {}
        }
    }

    fn show_notification(&self, device: &Device, n: proto::NotificationEvent) {
        if n.is_group_summary {
            return;
        }
        self.notif_owner.lock().unwrap().insert(n.id.clone(), device.id.clone());
        eprintln!("Notification from {}: {} — {}", device.name, n.app_label, n.title);
        let title = if n.title.is_empty() { n.app_label.clone() } else { format!("{} · {}", n.app_label, n.title) };
        let _ = self.app.notification().builder().title(&title).body(&n.text).show();
        let _ = self.app.emit(
            "notification",
            NotifView {
                id: n.id,
                device: device.id.clone(),
                app: n.app_label,
                title: n.title,
                text: n.text,
                time: n.timestamp,
                can_reply: n.has_reply_action,
                is_call: n.is_call,
            },
        );
    }

    // ─── Clipboard ───────────────────────────────────────────────────────────

    fn apply_clipboard(&self, text: &str) {
        self.clip.lock().unwrap().applied_remote = text.to_string();
        if let Err(e) = arboard::Clipboard::new().and_then(|mut c| c.set_text(text)) {
            eprintln!("Clipboard write failed: {e}");
        }
    }

    /// Polls, like the Mac (NSPasteboard has no change event either).
    /// ponytail: 500 ms poll; AddClipboardFormatListener if the lag shows.
    pub fn watch_clipboard(self: Arc<Self>) {
        std::thread::spawn(move || {
            let mut clipboard = arboard::Clipboard::new().ok();
            // What is already there at launch is not a new copy.
            if let Some(text) = clipboard.as_mut().and_then(|c| c.get_text().ok()) {
                self.clip.lock().unwrap().last_seen = text;
            }
            loop {
                std::thread::sleep(Duration::from_millis(500));
                if clipboard.is_none() {
                    clipboard = arboard::Clipboard::new().ok();
                }
                let Some(text) = clipboard.as_mut().and_then(|c| c.get_text().ok()) else { continue };
                {
                    let mut st = self.clip.lock().unwrap();
                    if text == st.last_seen {
                        continue;
                    }
                    st.last_seen = text.clone();
                    if text == st.applied_remote {
                        continue;
                    }
                }
                let update = proto::ClipboardUpdate {
                    content: text,
                    mime_type: "text/plain".into(),
                    timestamp: now_ms(),
                    origin_id: self.origin_id.clone(),
                    ..Default::default()
                };
                self.broadcast_except(None, &env(Payload::Clipboard(update)));
            }
        });
    }

    // ─── Actions from the window ─────────────────────────────────────────────

    pub fn reply(&self, id: &str, text: &str) -> bool {
        let Some(device) = self.notif_owner.lock().unwrap().get(id).cloned() else { return false };
        self.send_to(
            &device,
            env(Payload::NotifAction(proto::NotificationAction {
                action_id: id.into(),
                label: text.into(),
                is_reply: true,
            })),
        )
    }

    pub fn dismiss(&self, id: &str) {
        if let Some(device) = self.notif_owner.lock().unwrap().remove(id) {
            self.send_to(&device, env(Payload::NotifDismiss(proto::NotificationDismiss { id: id.into(), ..Default::default() })));
        }
    }

    pub fn call(&self, device: &str, action: &str) -> bool {
        use proto::call_control::Action;
        let action = match action {
            "answer" => Action::Answer,
            "reject" => Action::Reject,
            "end" => Action::End,
            _ => return false,
        };
        self.send_to(device, env(Payload::CallControl(proto::CallControl { action: action as i32 })))
    }

    pub fn media(&self, device: &str, action: &str) -> bool {
        use proto::media_command::Action;
        let action = match action {
            "toggle" => Action::PlayPause,
            "next" => Action::Next,
            "previous" => Action::Previous,
            _ => return false,
        };
        self.send_to(device, env(Payload::MediaCommand(proto::MediaCommand { action: action as i32 })))
    }

    pub fn ring(&self, device: &str, on: bool) -> bool {
        use proto::remote_action::Action;
        let action = if on { Action::Ring } else { Action::StopRing };
        self.send_to(device, env(Payload::RemoteAction(proto::RemoteAction { action: action as i32, url: String::new() })))
    }

    /// The phone accepts http(s) only (RemoteActionHandler.isAllowedUrl).
    pub fn open_url(&self, device: &str, url: &str) -> bool {
        let url = url.trim();
        if !(url.starts_with("http://") || url.starts_with("https://")) || url.len() < 9 {
            return false;
        }
        let action = proto::remote_action::Action::OpenUrl as i32;
        self.send_to(device, env(Payload::RemoteAction(proto::RemoteAction { action, url: url.into() })))
    }

    // ─── Files to the phone ──────────────────────────────────────────────────

    pub fn send_files(self: &Arc<Self>, device: String, paths: Vec<String>) {
        let hub = self.clone();
        tokio::spawn(async move {
            for path in paths {
                let path = PathBuf::from(path);
                if let Err(e) = hub.send_file(&device, &path).await {
                    hub.transfer(TransferView {
                        id: uuid::Uuid::new_v4().to_string(),
                        name: file_name(&path),
                        incoming: false,
                        done: 0,
                        total: 0,
                        finished: true,
                        error: Some(e),
                    });
                }
            }
        });
    }

    async fn send_file(&self, device: &str, path: &Path) -> Result<(), String> {
        let tx = self.sessions.lock().unwrap().get(device).map(|s| s.tx.clone()).ok_or("Phone is not connected")?;
        let meta = tokio::fs::metadata(path).await.map_err(|e| e.to_string())?;
        if !meta.is_file() {
            return Err("Folders can't be sent — zip it first".into());
        }
        let name = file_name(path);
        let size = meta.len();

        // The phone checks this against what it wrote; a first pass is cheap
        // next to a corrupt file that reports success.
        let mut file = tokio::fs::File::open(path).await.map_err(|e| e.to_string())?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; CHUNK];
        loop {
            let n = file.read(&mut buf).await.map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let checksum: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();

        let id = uuid::Uuid::new_v4().to_string();
        let cancelled = Arc::new(AtomicBool::new(false));
        self.outgoing.lock().unwrap().insert(id.clone(), cancelled.clone());
        let view = |done: u64| TransferView { id: id.clone(), name: name.clone(), incoming: false, done, total: size, finished: false, error: None };
        self.transfer(view(0));

        let start = proto::FileTransferStart {
            filename: name.clone(),
            size,
            checksum,
            transfer_id: id.clone(),
            mime_type: "application/octet-stream".into(),
        };
        tx.send(env(Payload::FileStart(start))).await.map_err(|_| "Phone disconnected")?;

        let mut file = tokio::fs::File::open(path).await.map_err(|e| e.to_string())?;
        let mut offset = 0u64;
        let mut last_percent = 0;
        while !cancelled.load(Ordering::SeqCst) {
            let n = file.read(&mut buf).await.map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            let chunk = proto::FileChunk { transfer_id: id.clone(), offset, data: buf[..n].to_vec() };
            // A bounded channel: awaiting here is the backpressure that keeps a
            // fast disk from outrunning the socket.
            tx.send(env(Payload::FileChunk(chunk))).await.map_err(|_| "Phone disconnected")?;
            offset += n as u64;
            let percent = offset * 100 / size.max(1);
            if percent != last_percent {
                last_percent = percent;
                self.transfer(view(offset));
            }
        }
        Ok(()) // Finished or failed is the phone's call, via FileAck.
    }

    fn outgoing_ack(&self, ack: proto::FileTransferAck) {
        if ack.error.is_empty() && !ack.complete {
            return;
        }
        let Some(cancelled) = self.outgoing.lock().unwrap().remove(&ack.transfer_id) else { return };
        cancelled.store(true, Ordering::SeqCst);
        self.transfer(TransferView {
            id: ack.transfer_id,
            name: String::new(),
            incoming: false,
            done: ack.bytes_received,
            total: ack.bytes_received,
            finished: true,
            error: (!ack.error.is_empty()).then_some(ack.error),
        });
    }

    fn transfer(&self, view: TransferView) {
        let _ = self.app.emit("transfer", view);
    }
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into())
}

// ─── Files from a phone ──────────────────────────────────────────────────────

/// Transfers in flight on one connection. Written to `name.part` in Downloads
/// and renamed only once every byte is in and the checksum matches, so a
/// dropped link never leaves a file that looks complete.
#[derive(Default)]
struct Incoming {
    open: HashMap<String, InFile>,
}

struct InFile {
    file: std::fs::File,
    part: PathBuf,
    dest: PathBuf,
    name: String,
    size: u64,
    written: u64,
    hasher: Sha256,
    checksum: String,
}

fn ack(id: &str, bytes: u64, complete: bool, error: &str) -> proto::FileTransferAck {
    proto::FileTransferAck { transfer_id: id.into(), bytes_received: bytes, complete, error: error.into() }
}

/// `name`, `name (1)`, … — never overwrite something already in Downloads.
fn free_path(dir: &Path, name: &str) -> PathBuf {
    let path = Path::new(name);
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
    let ext = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let taken = |p: &Path| p.exists() || PathBuf::from(format!("{}.part", p.display())).exists();
    let mut candidate = dir.join(name);
    let mut n = 1;
    while taken(&candidate) {
        candidate = dir.join(format!("{stem} ({n}){ext}"));
        n += 1;
    }
    candidate
}

/// The phone picks the name; never let it pick the directory.
fn sanitize(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = base.chars().map(|c| if r#"<>:"|?*"#.contains(c) || c.is_control() { '_' } else { c }).collect();
    let clean = clean.trim().trim_matches('.').to_string();
    if clean.is_empty() { "file".into() } else { clean }
}

impl Incoming {
    fn start(&mut self, s: proto::FileTransferStart, app: &AppHandle) -> Option<proto::FileTransferAck> {
        let name = sanitize(&s.filename);
        let dir = dirs::download_dir().unwrap_or_else(std::env::temp_dir);
        let dest = free_path(&dir, &name);
        let part = PathBuf::from(format!("{}.part", dest.display()));
        let file = match std::fs::File::create(&part) {
            Ok(f) => f,
            Err(e) => return Some(ack(&s.transfer_id, 0, false, &format!("Can't write to Downloads: {e}"))),
        };
        let _ = app.emit("transfer", TransferView { id: s.transfer_id.clone(), name: name.clone(), incoming: true, done: 0, total: s.size, finished: false, error: None });
        let f = InFile { file, part, dest, name, size: s.size, written: 0, hasher: Sha256::new(), checksum: s.checksum.to_lowercase() };
        self.open.insert(s.transfer_id.clone(), f);
        // An empty file has no chunks to wait for.
        if s.size == 0 {
            return self.finish(&s.transfer_id, app);
        }
        None
    }

    fn chunk(&mut self, c: proto::FileChunk, app: &AppHandle) -> Option<proto::FileTransferAck> {
        let f = self.open.get_mut(&c.transfer_id)?;
        // Strictly in order, as both senders stream; a gap fails the transfer
        // rather than writing a corrupt file that reports success.
        let error = if c.offset != f.written {
            Some(format!("Expected offset {}, got {}", f.written, c.offset))
        } else if f.written + c.data.len() as u64 > f.size {
            Some("More data than announced".to_string())
        } else {
            f.file.write_all(&c.data).err().map(|e| e.to_string())
        };
        if let Some(error) = error {
            self.fail(&c.transfer_id, &error, app);
            return Some(ack(&c.transfer_id, 0, false, &error));
        }
        f.hasher.update(&c.data);
        let before = f.written * 100 / f.size.max(1);
        f.written += c.data.len() as u64;
        if f.written == f.size {
            return self.finish(&c.transfer_id, app);
        }
        if f.written * 100 / f.size.max(1) != before {
            let _ = app.emit("transfer", TransferView { id: c.transfer_id, name: f.name.clone(), incoming: true, done: f.written, total: f.size, finished: false, error: None });
        }
        None
    }

    fn finish(&mut self, id: &str, app: &AppHandle) -> Option<proto::FileTransferAck> {
        let f = self.open.remove(id)?;
        let digest: String = f.hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
        drop(f.file);
        // The phone does not send a checksum yet; the Mac does.
        let error = if !f.checksum.is_empty() && f.checksum != digest {
            Some("Checksum mismatch — file corrupted in transit".to_string())
        } else {
            std::fs::rename(&f.part, &f.dest).err().map(|e| e.to_string())
        };
        if let Some(error) = &error {
            let _ = std::fs::remove_file(&f.part);
            let _ = app.emit("transfer", TransferView { id: id.into(), name: f.name, incoming: true, done: f.written, total: f.size, finished: true, error: Some(error.clone()) });
            return Some(ack(id, f.written, false, error));
        }
        let _ = app.emit("transfer", TransferView { id: id.into(), name: f.name, incoming: true, done: f.size, total: f.size, finished: true, error: None });
        Some(ack(id, f.size, true, ""))
    }

    fn fail(&mut self, id: &str, error: &str, app: &AppHandle) {
        if let Some(f) = self.open.remove(id) {
            drop(f.file);
            let _ = std::fs::remove_file(&f.part);
            let _ = app.emit("transfer", TransferView { id: id.into(), name: f.name, incoming: true, done: f.written, total: f.size, finished: true, error: Some(error.into()) });
        }
    }

    fn cancel(&mut self, id: &str, app: &AppHandle) {
        self.fail(id, "Cancelled on the phone", app);
    }

    /// The link dropped mid-transfer: no resume yet, so discard.
    fn abandon(&mut self) {
        for (_, f) in self.open.drain() {
            drop(f.file);
            let _ = std::fs::remove_file(&f.part);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_keeps_files_in_downloads() {
        assert_eq!(sanitize("../../Windows/System32/evil.dll"), "evil.dll");
        assert_eq!(sanitize(r"C:\Users\x\a.txt"), "a.txt");
        assert_eq!(sanitize("what?.txt"), "what_.txt");
        assert_eq!(sanitize(".."), "file");
        assert_eq!(sanitize(""), "file");
    }

    #[test]
    fn free_path_never_overwrites() {
        let dir = std::env::temp_dir().join(format!("bridg-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(free_path(&dir, "a.txt"), dir.join("a.txt"));
        std::fs::write(dir.join("a.txt"), b"x").unwrap();
        assert_eq!(free_path(&dir, "a.txt"), dir.join("a (1).txt"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
