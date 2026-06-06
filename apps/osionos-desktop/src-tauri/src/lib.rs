use std::path::PathBuf;
use std::process::Command;

/// Resolve the Track Binocle repo dir that holds docker-compose.yml.
/// Override with TRACK_BINOCLE_HOME; defaults to ~/Documents/ft_transcendence.
fn track_binocle_home() -> PathBuf {
    if let Ok(dir) = std::env::var("TRACK_BINOCLE_HOME") {
        return PathBuf::from(dir);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(format!("{home}/Documents/ft_transcendence"))
}

/// Boot the local suite (osionos + Mail + Calendar + lean BaaS) in the
/// background so opening this app brings the whole thing up. Best-effort: the
/// bundled splash polls osionos and navigates to it once reachable. A future
/// distributable build will drive this from a bundled compose + published images.
fn boot_suite() {
    let home = track_binocle_home();
    if !home.join("docker-compose.yml").exists() {
        return;
    }
    let _ = Command::new("docker")
        .args(["compose", "--profile", "dev", "up", "-d"])
        .current_dir(&home)
        .spawn();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // WebKitGTK on Linux frequently binds its DMABUF renderer to the llvmpipe
    // (software) EGL device -> severe slowness even on a capable GPU. Forcing the
    // accelerated GL path fixes it. SCOPED to THIS app's process only: set_var here
    // affects only this binary's own webview. It does NOT touch the website, which
    // renders in a normal browser and never uses WebKitGTK.
    #[cfg(target_os = "linux")]
    std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");

    boot_suite();
    tauri::Builder::default()
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
