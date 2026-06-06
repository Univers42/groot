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

/// True if an AMD/ATI GPU (PCI vendor 0x1002) is present, so we only pin the
/// radeonsi driver on machines that actually have one.
#[cfg(target_os = "linux")]
fn is_amd_gpu() -> bool {
    if let Ok(entries) = std::fs::read_dir("/sys/class/drm") {
        for entry in entries.flatten() {
            if let Ok(vendor) = std::fs::read_to_string(entry.path().join("device/vendor")) {
                if vendor.trim().eq_ignore_ascii_case("0x1002") {
                    return true;
                }
            }
        }
    }
    false
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // WebKitGTK GPU path (Linux). Keep WebKit's DMABUF (GPU) renderer ON — forcing
    // it OFF made WebKit fall back to the llvmpipe SOFTWARE renderer (the cause of
    // the severe latency). On AMD GPUs we additionally pin the radeonsi Gallium
    // driver so EGL doesn't pick the software device. All defaults are only applied
    // when unset, so they stay overridable, and radeonsi is gated on an AMD GPU
    // being present so this is portable to Intel/NVIDIA machines. Scoped to this
    // binary only; never touches the website (rendered in a browser).
    #[cfg(target_os = "linux")]
    {
        if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "0");
        }
        if is_amd_gpu() {
            if std::env::var_os("MESA_LOADER_DRIVER_OVERRIDE").is_none() {
                std::env::set_var("MESA_LOADER_DRIVER_OVERRIDE", "radeonsi");
            }
            if std::env::var_os("GALLIUM_DRIVER").is_none() {
                std::env::set_var("GALLIUM_DRIVER", "radeonsi");
            }
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
