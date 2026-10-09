//! This computer's identity and the phones paired with it.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use x25519_dalek::{PublicKey, StaticSecret};

#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    /// Base64, as the phone sends it in PairRequest.
    pub public_key: String,
}

pub struct Store {
    devices_file: PathBuf,
}

impl Store {
    pub fn open() -> Self {
        let dir = dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("Bridg");
        let _ = std::fs::create_dir_all(&dir);
        Self { devices_file: dir.join("devices.json") }
    }

    /// The X25519 identity, from the OS credential store (Windows Credential
    /// Manager). Only a genuinely missing entry mints a new one: replacing the
    /// identity on any other error would silently unpair every phone — the
    /// lesson KeychainManager.getOrCreatePublicKey on the Mac learned.
    pub fn identity(&self) -> Result<StaticSecret, String> {
        let entry = keyring::Entry::new("com.bridg.desktop", "identity").map_err(|e| e.to_string())?;
        match entry.get_password() {
            Ok(b64) => {
                let bytes: [u8; 32] = B64
                    .decode(b64)
                    .ok()
                    .and_then(|b| b.try_into().ok())
                    .ok_or("stored identity is corrupt")?;
                Ok(StaticSecret::from(bytes))
            }
            Err(keyring::Error::NoEntry) => {
                let secret = StaticSecret::random_from_rng(rand::rngs::OsRng);
                entry.set_password(&B64.encode(secret.to_bytes())).map_err(|e| e.to_string())?;
                Ok(secret)
            }
            Err(e) => Err(format!("credential store unavailable: {e}")),
        }
    }

    pub fn devices(&self) -> Vec<Device> {
        std::fs::read(&self.devices_file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn save(&self, devices: &[Device]) {
        if let Ok(json) = serde_json::to_vec_pretty(devices) {
            let _ = std::fs::write(&self.devices_file, json);
        }
    }

    /// Re-pairing the same phone (same key) keeps its id instead of adding a twin.
    pub fn add(&self, name: &str, public_key: &[u8]) -> Device {
        let key = B64.encode(public_key);
        let mut devices = self.devices();
        let device = match devices.iter_mut().find(|d| d.public_key == key) {
            Some(d) => {
                d.name = name.to_string();
                d.clone()
            }
            None => {
                let d = Device { id: uuid::Uuid::new_v4().to_string(), name: name.to_string(), public_key: key };
                devices.push(d.clone());
                d
            }
        };
        self.save(&devices);
        device
    }

    pub fn remove(&self, id: &str) {
        let mut devices = self.devices();
        devices.retain(|d| d.id != id);
        self.save(&devices);
    }
}

pub fn public_key(secret: &StaticSecret) -> [u8; 32] {
    PublicKey::from(secret).to_bytes()
}
