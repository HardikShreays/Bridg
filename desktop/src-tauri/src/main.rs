// No console window behind the app in release builds on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod crypto;
mod hub;
mod store;

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/bridg.rs"));
}

use hub::Hub;
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Manager, State, WindowEvent};

type HubState<'a> = State<'a, Arc<Hub>>;

#[tauri::command]
fn snapshot(hub: HubState) -> hub::Snapshot {
    hub.snapshot()
}

#[tauri::command]
fn start_pairing(hub: HubState) -> Result<hub::PairingView, String> {
    hub.start_pairing()
}

#[tauri::command]
fn cancel_pairing(hub: HubState) {
    hub.cancel_pairing()
}

#[tauri::command]
fn unpair(hub: HubState, device: String) {
    hub.unpair(&device)
}

#[tauri::command]
fn reply(hub: HubState, id: String, text: String) -> bool {
    hub.reply(&id, &text)
}

#[tauri::command]
fn dismiss(hub: HubState, id: String) {
    hub.dismiss(&id)
}

#[tauri::command]
fn call(hub: HubState, device: String, action: String) -> bool {
    hub.call(&device, &action)
}

#[tauri::command]
fn media(hub: HubState, device: String, action: String) -> bool {
    hub.media(&device, &action)
}

#[tauri::command]
fn ring(hub: HubState, device: String, on: bool) -> bool {
    hub.ring(&device, on)
}

#[tauri::command]
fn open_url(hub: HubState, device: String, url: String) -> bool {
    hub.open_url(&device, &url)
}

#[tauri::command]
fn send_files(hub: HubState, device: String, paths: Vec<String>) {
    hub.send_files(device, paths)
}

fn show_window(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            let hub = Hub::new(app.handle().clone())?;
            app.manage(hub.clone());
            tauri::async_runtime::spawn(hub.clone().run());
            hub.watch_clipboard();

            // A hub that quits when its window closes drops the phone; closing
            // hides to the tray, and Quit lives there.
            let open = MenuItem::with_id(app, "open", "Open Bridg", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Bridg", true, None::<&str>)?;
            TrayIconBuilder::new()
                .icon(app.default_window_icon().cloned().expect("bundled icon"))
                .tooltip("Bridg")
                .menu(&Menu::with_items(app, &[&open, &quit])?)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            snapshot,
            start_pairing,
            cancel_pairing,
            unpair,
            reply,
            dismiss,
            call,
            media,
            ring,
            open_url,
            send_files
        ])
        .run(tauri::generate_context!())
        .expect("Bridg failed to start");
}
