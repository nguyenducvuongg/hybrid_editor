// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 hybrid_edit_vid contributors

//! Single Renderer Parity (`I3`, `P2`) regression test:
//! Verifies a sub-16:9 clip + transparent PNG overlay produces solid opaque black `[0, 0, 0, 255]`
//! in uncovered canvas regions across both core preview frame rendering and VideoToolbox MP4 export.

use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::AtomicBool;

use concat_export::{
    ClipKind, ExportClip, ExportRequest, PreviewFrameRequest, Reporter, preview_frame, render_on,
};
use concat_media::{ColorRange, DecodeOptions, Decoder, FrameSource, RateMode, ReaderPool, VideoCodec};
use concat_project::model::ColorSpace;

#[test]
fn p2_canvas_alpha_parity_between_preview_and_videotoolbox_export() {
    let dir = std::env::temp_dir().join(format!("hybrid-p2-parity-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");

    // 1. Generate a 1-second 320x240 solid red H.264 clip (sub-16:9) via ffmpeg.
    let sub_clip_path = dir.join("sub_clip.mp4");
    let status = Command::new("ffmpeg")
        .args([
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=red:s=320x240:r=30:d=1",
            "-c:v",
            "h264_videotoolbox",
            "-pix_fmt",
            "yuv420p",
        ])
        .arg(&sub_clip_path)
        .status()
        .expect("ffmpeg available");
    assert!(status.success(), "ffmpeg failed creating sub-16:9 input clip");

    // 2. Generate a 640x360 PNG with transparent outer border (alpha=0) and opaque blue center.
    let overlay_png_path = dir.join("overlay.png");
    {
        let file = std::fs::File::create(&overlay_png_path).expect("create png");
        let mut enc = png::Encoder::new(file, 640, 360);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().expect("png header");
        let mut rgba = vec![0u8; 640 * 360 * 4];
        for y in 120..240 {
            for x in 240..400 {
                let idx = (y * 640 + x) * 4;
                rgba[idx] = 20;
                rgba[idx + 1] = 80;
                rgba[idx + 2] = 240;
                rgba[idx + 3] = 255;
            }
        }
        writer.write_image_data(&rgba).expect("write png");
    }

    let mut base_clip = ExportClip::blank(ClipKind::Video, 0.0, 0.5, 0);
    base_clip.path = sub_clip_path.to_string_lossy().into_owned();
    base_clip.media_width = Some(320);
    base_clip.media_height = Some(240);
    base_clip.has_audio = Some(false);
    base_clip.scale = 0.5;

    let mut png_clip = ExportClip::blank(ClipKind::Image, 0.0, 0.5, 1);
    png_clip.path = overlay_png_path.to_string_lossy().into_owned();
    png_clip.media_width = Some(640);
    png_clip.media_height = Some(360);
    png_clip.has_audio = Some(false);

    let clips = vec![base_clip, png_clip];

    // 3. Render core preview frame at t=0.1s (640x360 raw RGBA).
    let pool = ReaderPool::with_defaults();
    let preview_rgba = preview_frame(
        &pool,
        &PreviewFrameRequest {
            time: 0.1,
            width: 640,
            height: 360,
            rate_num: 30,
            rate_den: 1,
            color_space: ColorSpace::Sdr,
            canvas: [0, 0, 0, 255],
            clips: clips.clone(),
        },
    )
    .expect("preview_frame succeeds");
    assert_eq!(preview_rgba.len(), 640 * 360 * 4);

    let preview_px = |x: usize, y: usize| -> [u8; 4] {
        let i = (y * 640 + x) * 4;
        [
            preview_rgba[i],
            preview_rgba[i + 1],
            preview_rgba[i + 2],
            preview_rgba[i + 3],
        ]
    };

    // 4. Export VideoToolbox MP4 through concat_export::render_on.
    let export_mp4 = dir.join("export.mp4");
    let cancel = AtomicBool::new(false);
    let mut progress = |_: i64, _: i64, _: &'static str| {};
    let written = render_on(
        &ExportRequest {
            output: export_mp4.to_string_lossy().into_owned(),
            width: 640,
            height: 360,
            rate_num: 30,
            rate_den: 1,
            crf: 20,
            preset: "medium".into(),
            codec: VideoCodec::H264,
            ten_bit: false,
            rate_mode: RateMode::Vbr,
            bitrate_kbps: 0,
            color_range: ColorRange::Limited,
            color_space: ColorSpace::Sdr,
            hdr: false,
            effect_time_offset: 0.0,
            canvas: [0, 0, 0, 255],
            clips,
            resume: None,
        },
        None,
        Reporter {
            progress: &mut progress,
            cancel: &cancel,
        },
    )
    .expect("VideoToolbox export succeeds");
    assert_eq!(PathBuf::from(&written), export_mp4);

    // 5. Decode exported frame at t=0.1s (frame index 3) and assert corner + center parity.
    let mut decoder = Decoder::open(&export_mp4, &DecodeOptions::default()).expect("open export");
    let mut exported_frame = None;
    for _ in 0..=3 {
        exported_frame = decoder.next_frame().expect("decode frame");
    }
    let exported = exported_frame.expect("frame 3 present");

    let prev_corner = preview_px(4, 4);
    let exp_corner = exported.pixel(4, 4).expect("export corner");
    assert_eq!(prev_corner, [0, 0, 0, 255], "preview margin must be opaque black");
    assert!(
        exp_corner[0] <= 8 && exp_corner[1] <= 8 && exp_corner[2] <= 8 && exp_corner[3] == 255,
        "export margin must be solid black, got {exp_corner:?}"
    );

    let prev_center = preview_px(320, 180);
    let exp_center = exported.pixel(320, 180).expect("export center");
    assert!(
        prev_center[2] >= 220 && exp_center[2] >= 200,
        "center blue overlay must match between preview {prev_center:?} and export {exp_center:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
