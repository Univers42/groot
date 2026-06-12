//! PB file storage: bytes live at `{storage_root}/{collection id}/{record
//! id}/{stored name}`, the record's file column stores the generated name
//! (PB shape: `{sanitized base}_{10 random}.{ext}`). Serving is
//! `GET /api/files/{collection}/{recordId}/{filename}` with `?thumb=` crop/
//! fit variants for jpeg/png, cached as siblings (`thumbs_{spec}_{name}`).

use axum::extract::{Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use std::collections::HashMap;

use super::{pb_err, pb_of};
use crate::routes::AppState;

/// `photo one.PNG` → `photo_one_a1b2c3d4e5.PNG` — PB sanitizes the base and
/// KEEPS the original extension case (the m48 diff caught a lowercased ext).
pub(crate) fn stored_name(original: &str) -> String {
    let (base, ext) = match original.rsplit_once('.') {
        Some((b, e)) => (b, e.to_string()),
        None => (original, String::new()),
    };
    let safe: String = base
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
        .take(40)
        .collect();
    let rand: String = super::pb_id().chars().take(10).collect();
    if ext.is_empty() {
        format!("{safe}_{rand}")
    } else {
        format!("{safe}_{rand}.{ext}")
    }
}

fn content_type_of(name: &str) -> &'static str {
    match name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).as_deref() {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("svg") => "image/svg+xml",
        Some("pdf") => "application/pdf",
        Some("txt") => "text/plain; charset=utf-8",
        Some("json") => "application/json",
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css",
        Some("js" | "mjs") => "text/javascript",
        Some("mp4") => "video/mp4",
        Some("mp3") => "audio/mpeg",
        Some("zip") => "application/zip",
        _ => "application/octet-stream",
    }
}

/// A path segment must be exactly one safe component — no traversal.
fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
        && !s.contains("..")
}

/// `?thumb=WxH | WxHt | WxHb | WxHf | 0xH | Wx0` → resized bytes (png).
fn make_thumb(bytes: &[u8], spec: &str) -> Option<Vec<u8>> {
    let (dims, mode) = match spec.chars().last() {
        Some('t' | 'b' | 'f') => (&spec[..spec.len() - 1], spec.chars().last().unwrap_or('c')),
        _ => (spec, 'c'),
    };
    let (w_raw, h_raw) = dims.split_once('x')?;
    let w: u32 = w_raw.parse().ok()?;
    let h: u32 = h_raw.parse().ok()?;
    if w == 0 && h == 0 || w > 4000 || h > 4000 {
        return None;
    }
    let img = image::load_from_memory(bytes).ok()?;
    let out = match (w, h, mode) {
        // 0xH / Wx0: preserve aspect ratio on the free axis
        (0, h, _) => img.resize(u32::MAX, h, image::imageops::FilterType::Triangle),
        (w, 0, _) => img.resize(w, u32::MAX, image::imageops::FilterType::Triangle),
        // f = fit inside WxH (no crop)
        (w, h, 'f') => img.resize(w, h, image::imageops::FilterType::Triangle),
        // default/t/b = cover WxH then crop (center/top/bottom)
        (w, h, m) => {
            let covered = img.resize_to_fill(w, h, image::imageops::FilterType::Triangle);
            // resize_to_fill center-crops; t/b shift the crop window
            if m == 'c' {
                covered
            } else {
                let scale = f64::max(
                    w as f64 / img.width() as f64,
                    h as f64 / img.height() as f64,
                );
                let sw = (img.width() as f64 * scale).round() as u32;
                let sh = (img.height() as f64 * scale).round() as u32;
                let scaled = img.resize_exact(sw.max(w), sh.max(h), image::imageops::FilterType::Triangle);
                let y = if m == 't' { 0 } else { scaled.height().saturating_sub(h) };
                let x = (scaled.width().saturating_sub(w)) / 2;
                scaled.crop_imm(x, y, w, h)
            }
        }
    };
    let mut buf = std::io::Cursor::new(Vec::new());
    out.write_to(&mut buf, image::ImageFormat::Png).ok()?;
    Some(buf.into_inner())
}

/// GET /api/files/{collection}/{recordId}/{filename}[?thumb=spec]
async fn serve(
    State(state): State<AppState>,
    Path((cname, rid, filename)): Path<(String, String, String)>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::response::Response {
    let pb = match pb_of(&state) {
        Ok(p) => p,
        Err(r) => return r,
    };
    let Some(col) = pb.col_get(&cname) else {
        return pb_err(StatusCode::NOT_FOUND, "collection not found");
    };
    if !safe_segment(&rid) || !safe_segment(&filename) {
        return pb_err(StatusCode::BAD_REQUEST, "invalid path");
    }
    let dir = pb.storage_root.join(&col.id).join(&rid);
    let path = dir.join(&filename);
    let Ok(bytes) = tokio::fs::read(&path).await else {
        return pb_err(StatusCode::NOT_FOUND, "The requested resource wasn't found.");
    };

    if let Some(spec) = q.get("thumb").filter(|s| !s.is_empty()) {
        if !safe_segment(spec) {
            return pb_err(StatusCode::BAD_REQUEST, "invalid thumb spec");
        }
        let cache = dir.join(format!("thumbs_{spec}_{filename}"));
        if let Ok(cached) = tokio::fs::read(&cache).await {
            return ([(header::CONTENT_TYPE, "image/png")], cached).into_response();
        }
        let src = bytes.clone();
        let spec_owned = spec.clone();
        let made = tokio::task::spawn_blocking(move || make_thumb(&src, &spec_owned))
            .await
            .ok()
            .flatten();
        if let Some(thumb) = made {
            let _ = tokio::fs::write(&cache, &thumb).await;
            return ([(header::CONTENT_TYPE, "image/png")], thumb).into_response();
        }
        // not an image / bad spec → PB serves the original
    }
    (
        [
            (header::CONTENT_TYPE, content_type_of(&filename)),
            (header::CACHE_CONTROL, "max-age=2592000, public"),
        ],
        bytes,
    )
        .into_response()
}

/// Best-effort removal of a record's file directory (record deleted).
pub(crate) async fn remove_record_files(pb: &super::PbState, collection_id: &str, record_id: &str) {
    if !safe_segment(record_id) {
        return;
    }
    let dir = pb.storage_root.join(collection_id).join(record_id);
    let _ = tokio::fs::remove_dir_all(dir).await;
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/files/:collection/:record/:filename", get(serve))
}
