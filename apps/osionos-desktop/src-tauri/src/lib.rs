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
    // WebKitGTK GPU path (Linux). Many Mesa/driver combos make WebKit fall back
    // to the llvmpipe SOFTWARE renderer -> severe slowness even on a capable GPU.
    // We DEFAULT to disabling the DMABUF renderer, but only if the user hasn't set
    // it — so the right setting can be found by A/B testing without a rebuild, e.g.
    //   WEBKIT_DISABLE_DMABUF_RENDERER=0 osionos    (try the GPU DMABUF path)
    //   WEBKIT_DISABLE_COMPOSITING_MODE=1 osionos   (diagnostic)
    // Scoped to this binary only; never touches the website (rendered in a browser).
    #[cfg(target_os = "linux")]
    {
        if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
    }

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
