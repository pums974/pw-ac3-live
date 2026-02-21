use anyhow::{anyhow, Context, Result};
use log::info;
use pipewire as pw;
use pipewire::main_loop::MainLoop;
use pipewire::properties::properties;
use pipewire::spa::param::audio::{AudioFormat, AudioInfoRaw};
use pipewire::spa::utils::Direction;
use pipewire::stream::{StreamFlags, StreamRef};
use rtrb::{Consumer, Producer};

use std::io::{Read, Write};
use std::mem::size_of;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
#[cfg(target_os = "linux")]
use std::{
    ffi::{CStr, CString},
    ptr,
};

const INPUT_CHANNELS: usize = 6;
const OUTPUT_CHANNELS: usize = 2;
const SAMPLE_RATE: &str = "48000";
const SAMPLE_RATE_HZ: u32 = 48_000;
const STDOUT_READ_BUFFER_SIZE: usize = 4096;
const OUTPUT_FRAME_BYTES: usize = OUTPUT_CHANNELS * size_of::<i16>();
const DEFAULT_ALSA_LATENCY_US: u32 = 60_000;

#[derive(Debug, Clone)]
pub struct PipewireConfig {
    pub node_latency: String,
}

impl Default for PipewireConfig {
    fn default() -> Self {
        Self {
            node_latency: "64/48000".to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub enum OutputMode {
    Pipewire,
    Stdout,
    AlsaDirect { device: String, latency_us: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PlaybackTarget {
    connect_target_id: Option<u32>,
    target_object: Option<String>,
}

fn resolve_playback_target(target_node: Option<&str>) -> PlaybackTarget {
    let target_object = target_node
        .map(str::trim)
        .filter(|target| !target.is_empty())
        .map(str::to_string);

    let connect_target_id = target_object
        .as_deref()
        .and_then(|target| target.parse::<u32>().ok());

    PlaybackTarget {
        connect_target_id,
        target_object,
    }
}

fn build_playback_properties(target: &PlaybackTarget) -> pw::properties::Properties {
    let has_explicit_target = target.target_object.is_some() || target.connect_target_id.is_some();
    let mut playback_props = properties! {
        *pw::keys::NODE_NAME => "pw-ac3-live-output",
        *pw::keys::NODE_DESCRIPTION => "AC-3 Live Output",
        *pw::keys::APP_NAME => "pw-ac3-live",
        "audio.channels" => OUTPUT_CHANNELS.to_string(),
        "audio.position" => "FL,FR",
        "audio.rate" => SAMPLE_RATE,
        "audio.format" => "S16LE",
        "media.name" => "ac3-encoder-playback",
        "stream.is-live" => "true",
        "node.want-driver" => "true",
        // We link explicitly from the launcher/script to avoid accidental mixed routes.
        "node.autoconnect" => if has_explicit_target { "false" } else { "true" },
        // Keep IEC61937 bytes bit-transparent: no remix, no resample, no dither.
        "stream.dont-remix" => "true",
        "channelmix.disable" => "true",
        "channelmix.normalize" => "false",
        "resample.disable" => "true",
        "dither.method" => "none",
        "session.suspend-timeout-seconds" => "0",
    };

    if let Some(target_object) = target.target_object.as_deref() {
        // Works with both node names and numeric object IDs.
        playback_props.insert("target.object", target_object);
    }

    playback_props
}

#[cfg(target_os = "linux")]
mod alsa_output {
    use super::*;
    use libc::{c_char, c_int, c_uint, c_void};

    type SndPcmUframes = libc::c_ulong;
    type SndPcmSframes = libc::c_long;

    const SND_PCM_STREAM_PLAYBACK: c_int = 0;
    const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;
    const SND_PCM_FORMAT_S16_LE: c_int = 2;

    #[repr(C)]
    struct SndPcmHandle {
        _private: [u8; 0],
    }

    #[link(name = "asound")]
    unsafe extern "C" {
        fn snd_pcm_open(
            pcmp: *mut *mut SndPcmHandle,
            name: *const c_char,
            stream: c_int,
            mode: c_int,
        ) -> c_int;
        fn snd_pcm_close(pcm: *mut SndPcmHandle) -> c_int;
        fn snd_pcm_prepare(pcm: *mut SndPcmHandle) -> c_int;
        fn snd_pcm_drain(pcm: *mut SndPcmHandle) -> c_int;
        fn snd_pcm_recover(pcm: *mut SndPcmHandle, err: c_int, silent: c_int) -> c_int;
        fn snd_pcm_set_params(
            pcm: *mut SndPcmHandle,
            format: c_int,
            access: c_int,
            channels: c_uint,
            rate: c_uint,
            soft_resample: c_int,
            latency: c_uint,
        ) -> c_int;
        fn snd_pcm_writei(
            pcm: *mut SndPcmHandle,
            buffer: *const c_void,
            size: SndPcmUframes,
        ) -> SndPcmSframes;
        fn snd_strerror(errnum: c_int) -> *const c_char;
    }

    fn alsa_error(context: &str, err: c_int) -> anyhow::Error {
        // SAFETY: `snd_strerror` returns a pointer to a static NUL-terminated error string
        // for any ALSA error code. We only read it immediately and convert lossily.
        let detail = unsafe {
            let ptr = snd_strerror(err);
            if ptr.is_null() {
                format!("errno={err}")
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }
        };

        anyhow!("{context}: {detail} (code {err})")
    }

    pub(super) struct AlsaPlayback {
        handle: *mut SndPcmHandle,
    }

    impl AlsaPlayback {
        pub(super) fn open(device: &str, latency_us: u32) -> Result<Self> {
            let mut handle = ptr::null_mut();
            let device_cstr =
                CString::new(device).context("ALSA device contains interior NUL bytes")?;

            // SAFETY: `device_cstr` lives for the duration of this call, `handle` is a valid
            // out-pointer, and we request playback mode with no special flags.
            let open_result = unsafe {
                snd_pcm_open(
                    &mut handle,
                    device_cstr.as_ptr(),
                    SND_PCM_STREAM_PLAYBACK,
                    0,
                )
            };
            if open_result < 0 {
                return Err(alsa_error(
                    &format!("Failed to open ALSA playback device '{device}'"),
                    open_result,
                ));
            }

            // SAFETY: `handle` was successfully returned by ALSA and is valid until closed.
            let params_result = unsafe {
                snd_pcm_set_params(
                    handle,
                    SND_PCM_FORMAT_S16_LE,
                    SND_PCM_ACCESS_RW_INTERLEAVED,
                    OUTPUT_CHANNELS as c_uint,
                    SAMPLE_RATE_HZ,
                    0,
                    latency_us,
                )
            };
            if params_result < 0 {
                // SAFETY: `handle` was opened above; we close it on configuration failure.
                let _ = unsafe { snd_pcm_close(handle) };
                return Err(alsa_error(
                    &format!(
                        "Failed to configure ALSA device '{device}' ({} Hz, {}ch, S16LE, latency={}us)",
                        SAMPLE_RATE_HZ, OUTPUT_CHANNELS, latency_us
                    ),
                    params_result,
                ));
            }

            // SAFETY: `handle` is valid and configured; prepare transitions to a ready state.
            let prepare_result = unsafe { snd_pcm_prepare(handle) };
            if prepare_result < 0 {
                // SAFETY: `handle` was opened above; we close it on configuration failure.
                let _ = unsafe { snd_pcm_close(handle) };
                return Err(alsa_error(
                    &format!("Failed to prepare ALSA device '{device}'"),
                    prepare_result,
                ));
            }

            Ok(Self { handle })
        }

        pub(super) fn write_all(&mut self, data: &[u8]) -> Result<()> {
            let frame_count = data.len() / OUTPUT_FRAME_BYTES;
            if frame_count == 0 {
                return Ok(());
            }

            let mut written_frames = 0usize;
            while written_frames < frame_count {
                let offset_bytes = written_frames * OUTPUT_FRAME_BYTES;
                let ptr = data[offset_bytes..].as_ptr() as *const c_void;
                let frames_left = (frame_count - written_frames) as SndPcmUframes;

                // SAFETY: `self.handle` is a valid opened PCM handle. `ptr` points to
                // `frames_left * frame_size` bytes of initialized memory for this call.
                let ret = unsafe { snd_pcm_writei(self.handle, ptr, frames_left) };
                if ret > 0 {
                    written_frames += ret as usize;
                    continue;
                }
                if ret == 0 {
                    thread::sleep(Duration::from_micros(200));
                    continue;
                }

                // SAFETY: `self.handle` is valid and `ret` is an ALSA negative error code
                // returned by `snd_pcm_writei`.
                let recover = unsafe { snd_pcm_recover(self.handle, ret as c_int, 1) };
                if recover < 0 {
                    return Err(alsa_error("ALSA write/recover failed", recover));
                }
            }

            Ok(())
        }

        pub(super) fn drain(&mut self) {
            // SAFETY: `self.handle` is a valid opened PCM handle.
            let drain_result = unsafe { snd_pcm_drain(self.handle) };
            if drain_result < 0 {
                log::warn!(
                    "ALSA drain failed during shutdown: {}",
                    alsa_error("snd_pcm_drain", drain_result)
                );
            }
        }
    }

    impl Drop for AlsaPlayback {
        fn drop(&mut self) {
            if self.handle.is_null() {
                return;
            }
            // SAFETY: `self.handle` is owned by this struct and has not been closed yet.
            let _ = unsafe { snd_pcm_close(self.handle) };
            self.handle = ptr::null_mut();
        }
    }
}

fn parse_f32_plane_into(
    raw_data: &[u8],
    offset: usize,
    size: usize,
    out: &mut Vec<f32>,
) -> Option<()> {
    let end = offset.checked_add(size)?;
    let bytes = raw_data.get(offset..end)?;
    if !offset.is_multiple_of(size_of::<f32>()) || !bytes.len().is_multiple_of(size_of::<f32>()) {
        return None;
    }

    out.clear();
    out.reserve(bytes.len() / size_of::<f32>());
    for chunk in bytes.chunks_exact(size_of::<f32>()) {
        out.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
    }
    Some(())
}

fn parse_f32_interleaved_into(
    raw_data: &[u8],
    offset: usize,
    size: usize,
    channels: usize,
    out: &mut Vec<f32>,
) -> Option<()> {
    if channels == 0 {
        return None;
    }

    parse_f32_plane_into(raw_data, offset, size, out)?;
    let valid_len = out.len() - (out.len() % channels);
    out.truncate(valid_len);
    Some(())
}

fn parse_interleaved_from_stride_into(
    raw_data: &[u8],
    offset: usize,
    size: usize,
    stride: usize,
    out: &mut Vec<f32>,
) -> Option<()> {
    if stride == 0 {
        return None;
    }

    let end = offset.checked_add(size)?;
    let bytes = raw_data.get(offset..end)?;
    if bytes.len() < stride {
        return None;
    }

    let frame_count = bytes.len() / stride;
    if frame_count == 0 {
        return None;
    }

    if stride.is_multiple_of(size_of::<f32>()) {
        let channels = stride / size_of::<f32>();
        if (1..=INPUT_CHANNELS).contains(&channels) {
            out.clear();
            out.reserve(frame_count * INPUT_CHANNELS);
            for frame in 0..frame_count {
                let frame_offset = frame * stride;
                for ch in 0..INPUT_CHANNELS {
                    let sample = if ch < channels {
                        let base = frame_offset + ch * size_of::<f32>();
                        f32::from_le_bytes([
                            bytes[base],
                            bytes[base + 1],
                            bytes[base + 2],
                            bytes[base + 3],
                        ])
                    } else {
                        0.0
                    };
                    out.push(sample);
                }
            }
            return Some(());
        }
    }

    if stride.is_multiple_of(size_of::<i16>()) {
        let channels = stride / size_of::<i16>();
        if (1..=INPUT_CHANNELS).contains(&channels) {
            out.clear();
            out.reserve(frame_count * INPUT_CHANNELS);
            for frame in 0..frame_count {
                let frame_offset = frame * stride;
                for ch in 0..INPUT_CHANNELS {
                    let sample = if ch < channels {
                        let base = frame_offset + ch * size_of::<i16>();
                        let value = i16::from_le_bytes([bytes[base], bytes[base + 1]]);
                        // Map i16 PCM to [-1.0, 1.0) without overshooting on i16::MIN.
                        (value as f32) / 32768.0
                    } else {
                        0.0
                    };
                    out.push(sample);
                }
            }
            return Some(());
        }
    }

    None
}

fn run_stdout_output_loop<W: Write>(
    output_consumer: &mut Consumer<u8>,
    running: &AtomicBool,
    writer: &mut W,
) -> std::io::Result<()> {
    let mut buffer = [0u8; STDOUT_READ_BUFFER_SIZE];

    while running.load(Ordering::Relaxed) || output_consumer.slots() > 0 {
        match output_consumer.read(&mut buffer) {
            Ok(read) if read > 0 => {
                writer.write_all(&buffer[..read])?;
                writer.flush()?;
            }
            Ok(_) | Err(_) => thread::sleep(Duration::from_millis(1)),
        }
    }

    Ok(())
}

fn run_alsa_output_loop(
    output_consumer: &mut Consumer<u8>,
    running: &AtomicBool,
    device: &str,
    latency_us: u32,
) -> Result<()> {
    #[cfg(not(target_os = "linux"))]
    {
        let _ = output_consumer;
        let _ = running;
        let _ = device;
        let _ = latency_us;
        return Err(anyhow!("--alsa-direct is only supported on Linux"));
    }

    #[cfg(target_os = "linux")]
    {
        let mut alsa = alsa_output::AlsaPlayback::open(device, latency_us)?;
        let mut read_buffer = [0u8; STDOUT_READ_BUFFER_SIZE];
        let mut staging_buffer = [0u8; STDOUT_READ_BUFFER_SIZE + OUTPUT_FRAME_BYTES];
        let mut staged_len = 0usize;

        while running.load(Ordering::Relaxed) || output_consumer.slots() > 0 {
            match output_consumer.read(&mut read_buffer) {
                Ok(read) if read > 0 => {
                    let writable = read.min(staging_buffer.len().saturating_sub(staged_len));
                    if writable == 0 {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }

                    staging_buffer[staged_len..staged_len + writable]
                        .copy_from_slice(&read_buffer[..writable]);
                    staged_len += writable;

                    let aligned = staged_len - (staged_len % OUTPUT_FRAME_BYTES);
                    if aligned > 0 {
                        alsa.write_all(&staging_buffer[..aligned])?;
                        let remainder = staged_len - aligned;
                        if remainder > 0 {
                            staging_buffer.copy_within(aligned..staged_len, 0);
                        }
                        staged_len = remainder;
                    }
                }
                Ok(_) | Err(_) => thread::sleep(Duration::from_millis(1)),
            }
        }

        if staged_len > 0 {
            log::warn!(
                "Dropping {} trailing byte(s) not aligned to {}-byte audio frames",
                staged_len,
                OUTPUT_FRAME_BYTES
            );
        }

        alsa.drain();
        Ok(())
    }
}

fn build_audio_raw_format_param(format: AudioFormat, channels: u32) -> Result<Vec<u8>> {
    let mut audio_info = AudioInfoRaw::new();
    audio_info.set_format(format);
    audio_info.set_rate(SAMPLE_RATE_HZ);
    audio_info.set_channels(channels);

    // Explicitly set channel map to ensure correct port creation.
    // Using raw values from libspa::sys because AudioChannel enum is not stable/exposed in 0.8
    if channels == 6 {
        let mut position = [0u32; 64];
        position[0] = libspa::sys::SPA_AUDIO_CHANNEL_FL;
        position[1] = libspa::sys::SPA_AUDIO_CHANNEL_FR;
        position[2] = libspa::sys::SPA_AUDIO_CHANNEL_FC;
        position[3] = libspa::sys::SPA_AUDIO_CHANNEL_LFE;
        position[4] = libspa::sys::SPA_AUDIO_CHANNEL_SL;
        position[5] = libspa::sys::SPA_AUDIO_CHANNEL_SR;
        audio_info.set_position(position);
    } else if channels == 2 {
        let mut position = [0u32; 64];
        position[0] = libspa::sys::SPA_AUDIO_CHANNEL_FL;
        position[1] = libspa::sys::SPA_AUDIO_CHANNEL_FR;
        audio_info.set_position(position);
    }

    let obj = pw::spa::pod::Object {
        type_: pw::spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
        id: pw::spa::param::ParamType::EnumFormat.as_raw(),
        properties: audio_info.into(),
    };

    let serialized = pw::spa::pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &pw::spa::pod::Value::Object(obj),
    )
    .context("Failed to serialize PipeWire format pod")?;

    Ok(serialized.0.into_inner())
}

/// Runs the main PipeWire event loop.
pub fn run_pipewire_loop(
    input_producer: Producer<f32>,
    output_consumer: Consumer<u8>,
    target_node: Option<String>,
    use_stdout: bool,
    running: Arc<AtomicBool>,
) -> Result<()> {
    let output_mode = if use_stdout {
        OutputMode::Stdout
    } else {
        OutputMode::Pipewire
    };

    run_pipewire_loop_with_config(
        input_producer,
        output_consumer,
        target_node,
        output_mode,
        running,
        PipewireConfig::default(),
    )
}

pub fn run_pipewire_loop_with_config(
    input_producer: Producer<f32>,
    mut output_consumer: Consumer<u8>,
    target_node: Option<String>,
    output_mode: OutputMode,
    running: Arc<AtomicBool>,
    config: PipewireConfig,
) -> Result<()> {
    info!("Initializing PipeWire client...");
    let node_latency = if config.node_latency.trim().is_empty() {
        "64/48000"
    } else {
        config.node_latency.as_str()
    };
    let requested_latency_frames = node_latency
        .split('/')
        .next()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|frames| *frames > 0);

    pw::init();

    let mainloop = MainLoop::new(None)?;
    let context = pw::context::Context::new(&mainloop)?;
    let core = context.connect(None)?;

    // ------------------------------------------------------------------
    // 1. Create Capture Stream (Virtual Sink)
    // ------------------------------------------------------------------

    let mut props = properties! {
        *pw::keys::MEDIA_CLASS => "Audio/Sink",
        *pw::keys::NODE_NAME => "pw-ac3-live-input",
        *pw::keys::NODE_DESCRIPTION => "AC-3 Encoder Input",
        *pw::keys::APP_NAME => "pw-ac3-live",
        "audio.channels" => INPUT_CHANNELS.to_string(),
        "audio.position" => "FL,FR,FC,LFE,SL,SR",
        "audio.rate" => SAMPLE_RATE,
        "audio.format" => "F32LE",
        "node.latency" => node_latency,
    };
    if let Some(frames) = requested_latency_frames {
        let force_quantum = frames.to_string();
        props.insert("node.force-quantum", force_quantum.as_str());
        props.insert("node.lock-quantum", "true");
        props.insert("node.force-rate", SAMPLE_RATE);
        props.insert("node.lock-rate", "true");
        info!(
            "Capture stream requesting forced quantum/rate: {} frames @ {} Hz",
            frames, SAMPLE_RATE_HZ
        );
    }

    let data = Arc::new(Mutex::new(input_producer));
    let capture_layout_logged = Arc::new(AtomicBool::new(false));
    let mut interleaved_scratch = Vec::<f32>::new();
    let mut planar_channel_scratch: [Vec<f32>; INPUT_CHANNELS] =
        std::array::from_fn(|_| Vec::new());

    // Create stream first
    let capture_stream = pw::stream::Stream::new(&core, "ac3-encoder-capture", props)?;

    // Add listener for process callback
    let _capture_listener = capture_stream
        .add_local_listener::<()>()
        .state_changed(|_stream, _data, old, new| {
            info!("Capture Stream state changed: {:?} -> {:?}", old, new);
        })
        .param_changed(|_stream, _data, id, param| {
            if id != pw::spa::param::ParamType::Format.as_raw() {
                return;
            }
            let Some(param) = param else {
                return;
            };
            let mut info = AudioInfoRaw::new();
            if info.parse(param).is_ok() {
                info!(
                    "Capture format negotiated: {:?}, rate={}, channels={}",
                    info.format(),
                    info.rate(),
                    info.channels()
                );
            }
        })
        .process(move |stream: &StreamRef, _data| {
            match stream.dequeue_buffer() {
                None => (),
                Some(mut buffer) => {
                    let datas = buffer.datas_mut();
                    if datas.is_empty() {
                        return;
                    }

                    let n_datas = datas.len();
                    if n_datas == 0 {
                        return;
                    }

                    interleaved_scratch.clear();

                    // PipeWire often exposes a single interleaved port even for 5.1.
                    if n_datas == 1 {
                        let chunk = datas[0].chunk();
                        let offset = chunk.offset() as usize;
                        let size = chunk.size() as usize;
                        let stride = chunk.stride().max(0) as usize;
                        if !capture_layout_logged.swap(true, Ordering::Relaxed) {
                            info!(
                                "Capture buffer layout: datas={}, size={}, stride={}",
                                n_datas, size, stride
                            );
                        }
                        if size == 0 {
                            return;
                        }

                        if let Some(raw_data) = datas[0].data() {
                            if parse_interleaved_from_stride_into(
                                raw_data,
                                offset,
                                size,
                                stride,
                                &mut interleaved_scratch,
                            )
                            .is_none()
                            {
                                let _ = parse_f32_interleaved_into(
                                    raw_data,
                                    offset,
                                    size,
                                    INPUT_CHANNELS,
                                    &mut interleaved_scratch,
                                );
                            }
                        }
                    } else {
                        if !capture_layout_logged.swap(true, Ordering::Relaxed) {
                            let stride = datas[0].chunk().stride().max(0);
                            let size = datas[0].chunk().size();
                            info!(
                                "Capture buffer layout: datas={}, first_size={}, first_stride={}",
                                n_datas, size, stride
                            );
                        }
                        // Planar input path: gather channels and interleave.
                        for samples in &mut planar_channel_scratch {
                            samples.clear();
                        }
                        let mut samples_per_channel: Option<usize> = None;

                        for (i, samples) in planar_channel_scratch
                            .iter_mut()
                            .enumerate()
                            .take(INPUT_CHANNELS.min(n_datas))
                        {
                            let chunk = datas[i].chunk();
                            let offset = chunk.offset() as usize;
                            let size = chunk.size() as usize;
                            if size == 0 {
                                continue;
                            }

                            if let Some(raw_data) = datas[i].data() {
                                if parse_f32_plane_into(raw_data, offset, size, samples).is_some() {
                                    if samples.is_empty() {
                                        continue;
                                    }
                                    samples_per_channel = Some(
                                        samples_per_channel
                                            .map(|n| n.min(samples.len()))
                                            .unwrap_or(samples.len()),
                                    );
                                }
                            }
                        }

                        let n_samples = match samples_per_channel {
                            Some(0) | None => return,
                            Some(n) => n,
                        };

                        interleaved_scratch.reserve(n_samples * INPUT_CHANNELS);
                        for s in 0..n_samples {
                            for channel in planar_channel_scratch.iter().take(INPUT_CHANNELS) {
                                interleaved_scratch.push(channel.get(s).copied().unwrap_or(0.0));
                            }
                        }
                    }

                    if interleaved_scratch.is_empty() {
                        return;
                    }

                    if let Ok(mut producer) = data.try_lock() {
                        let writable = producer.slots().min(interleaved_scratch.len());
                        let frame_aligned_writable = writable - (writable % INPUT_CHANNELS);
                        let dropped_frames = ((interleaved_scratch
                            .len()
                            .saturating_sub(frame_aligned_writable))
                            / INPUT_CHANNELS) as u64;

                        if frame_aligned_writable > 0 {
                            if let Ok(chunk) = producer.write_chunk_uninit(frame_aligned_writable) {
                                chunk.fill_from_iter(
                                    interleaved_scratch
                                        .iter()
                                        .take(frame_aligned_writable)
                                        .copied(),
                                );
                                dropped_frames
                            } else {
                                dropped_frames.saturating_add(
                                    (frame_aligned_writable / INPUT_CHANNELS) as u64,
                                )
                            }
                        } else {
                            dropped_frames
                        }
                    } else {
                        (interleaved_scratch.len() / INPUT_CHANNELS) as u64
                    };
                }
            }
        })
        .register()?;

    // Connect Capture Stream
    // Connect Capture Stream
    let capture_format_bytes =
        build_audio_raw_format_param(AudioFormat::F32LE, INPUT_CHANNELS as u32)?;
    let capture_format_pod = pw::spa::pod::Pod::from_bytes(&capture_format_bytes)
        .ok_or_else(|| anyhow!("Failed to parse capture format pod bytes"))?;
    let mut capture_params = [capture_format_pod];
    capture_stream.connect(
        Direction::Input,
        None,
        StreamFlags::AUTOCONNECT | StreamFlags::MAP_BUFFERS | StreamFlags::RT_PROCESS,
        &mut capture_params,
    )?;

    info!("PipeWire capture stream connected.");

    // ------------------------------------------------------------------
    // 2. Create Playback Stream (Output to HDMI)
    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // 2. Playback Handling
    // ------------------------------------------------------------------

    // We need to keep the stream alive if created
    let _playback_stream_handle: Option<pw::stream::Stream>;
    let _playback_listener_handle;
    let playback_target = resolve_playback_target(target_node.as_deref());

    match output_mode {
        OutputMode::Stdout => {
            // Shrink the process stdout pipe buffer to minimize end-to-end buffering.
            #[cfg(target_os = "linux")]
            {
                use std::os::unix::io::AsRawFd;
                let stdout_fd = std::io::stdout().as_raw_fd();
                const F_SETPIPE_SZ: libc::c_int = 1031;
                const F_GETPIPE_SZ: libc::c_int = 1032;

                // SAFETY: `stdout_fd` is owned by this process and valid for `fcntl`.
                let old = unsafe { libc::fcntl(stdout_fd, F_GETPIPE_SZ) };
                // SAFETY: same as above; we only request a smaller kernel pipe size.
                let ret = unsafe { libc::fcntl(stdout_fd, F_SETPIPE_SZ, 4096 as libc::c_int) };
                if ret > 0 {
                    info!("Shrunk process stdout pipe from {} to {} bytes", old, ret);
                } else {
                    log::warn!(
                        "Could not shrink process stdout pipe: {}",
                        std::io::Error::last_os_error()
                    );
                }
            }

            // Spawn a thread to read from ring buffer and write to stdout.
            let running_clone = running.clone();
            thread::spawn(move || {
                let mut stdout = std::io::stdout().lock();
                if let Err(e) = run_stdout_output_loop(
                    &mut output_consumer,
                    running_clone.as_ref(),
                    &mut stdout,
                ) {
                    log::error!("Failed to write to stdout: {}", e);
                    std::process::exit(1);
                }
            });
            info!("Outputting to stdout (playback stream disabled).");
            _playback_stream_handle = None;
            _playback_listener_handle = None;
        }
        OutputMode::AlsaDirect { device, latency_us } => {
            let alsa_latency_us = if latency_us == 0 {
                DEFAULT_ALSA_LATENCY_US
            } else {
                latency_us
            };
            let device_for_thread = device.clone();
            let running_clone = running.clone();
            thread::spawn(move || {
                if let Err(e) = run_alsa_output_loop(
                    &mut output_consumer,
                    running_clone.as_ref(),
                    &device_for_thread,
                    alsa_latency_us,
                ) {
                    log::error!("Direct ALSA output loop failed: {e:#}");
                    std::process::exit(1);
                }
            });
            info!(
                "Outputting directly to ALSA device '{}' (latency={}us, playback stream disabled).",
                device, alsa_latency_us
            );
            _playback_stream_handle = None;
            _playback_listener_handle = None;
        }
        OutputMode::Pipewire => {
            // Create Playback Stream (Output to HDMI/Sink)

            // Strategy: Use properties for Audio/Source
            let mut playback_props = build_playback_properties(&playback_target);
            playback_props.insert("node.latency", node_latency);
            if let Some(frames) = requested_latency_frames {
                let force_quantum = frames.to_string();
                playback_props.insert("node.force-quantum", force_quantum.as_str());
                playback_props.insert("node.lock-quantum", "true");
                playback_props.insert("node.force-rate", SAMPLE_RATE);
                playback_props.insert("node.lock-rate", "true");
                info!(
                    "Playback stream requesting forced quantum/rate: {} frames @ {} Hz",
                    frames, SAMPLE_RATE_HZ
                );
            }

            let output_ring_capacity_bytes = output_consumer.buffer().capacity();
            let playback_target_quantum_bytes = requested_latency_frames
                .map(|frames| frames.saturating_mul(OUTPUT_FRAME_BYTES))
                .filter(|bytes| *bytes > 0)
                .unwrap_or(0);

            if playback_target_quantum_bytes > 0 {
                info!(
                    "Playback target quantum: {} frames / {} bytes (ring capacity: {} bytes)",
                    requested_latency_frames.unwrap_or(0),
                    playback_target_quantum_bytes,
                    output_ring_capacity_bytes
                );
            }

            let output_data = Arc::new(Mutex::new(output_consumer));
            let playback_primed = Arc::new(AtomicBool::new(false));
            let playback_prefill_logged = Arc::new(AtomicBool::new(false));
            let playback_callback_quantum_logged = Arc::new(AtomicBool::new(false));

            // Create stream
            let playback_stream =
                pw::stream::Stream::new(&core, "ac3-encoder-playback", playback_props)?;

            let playback_listener = playback_stream
            .add_local_listener::<()>()
            .state_changed(|_stream, _data, old, new| {
                info!("Playback Stream state changed: {:?} -> {:?}", old, new);
            })
            .param_changed(|_stream, _data, id, param| {
                if id != pw::spa::param::ParamType::Format.as_raw() {
                    return;
                }
                let Some(param) = param else {
                    return;
                };
                let mut info = AudioInfoRaw::new();
                if info.parse(param).is_ok() {
                    info!(
                        "Playback format negotiated: {:?}, rate={}, channels={}",
                        info.format(),
                        info.rate(),
                        info.channels()
                    );
                }
            })
            .process(
                move |stream: &StreamRef, _data| match stream.dequeue_buffer() {
                    None => (),
                    Some(mut buffer) => {

                        let datas = buffer.datas_mut();
                        if datas.is_empty() {
                            return;
                        }


                        let (to_write, _) = {
                            let Some(raw_data) = datas[0].data() else {
                                return;
                            };
                            let max_writable = raw_data.len();
                            if max_writable == 0 {
                                return;
                            }

                            let mut target_write = max_writable;
                            if output_ring_capacity_bytes > 0 {
                                target_write = target_write.min(output_ring_capacity_bytes);
                            }
                            target_write = (target_write / OUTPUT_FRAME_BYTES) * OUTPUT_FRAME_BYTES;
                            if target_write == 0 {
                                return;
                            }

                            if playback_target_quantum_bytes > 0
                                && target_write > playback_target_quantum_bytes
                                && !playback_callback_quantum_logged
                                    .swap(true, Ordering::Relaxed)
                            {
                                info!(
                                    "Playback callback writable quantum {} bytes exceeds requested latency quantum {} bytes; draining callback-sized chunks for stability.",
                                    target_write,
                                    playback_target_quantum_bytes
                                );
                            }

                            // Keep stream timing stable: always output a full target quantum.
                            raw_data[..target_write].fill(0);

                            let prefill_limit = output_ring_capacity_bytes.max(target_write);
                            // Prime only one callback quantum. Priming deeper on very large
                            // loopback quantums (e.g. 64 KiB+) makes the ring sit near-full,
                            // which amplifies backpressure and capture drops.
                            let prefill_target = target_write.min(prefill_limit);
                            if let Ok(mut consumer) = output_data.try_lock() {
                                let available = consumer.slots();


                                if !playback_primed.load(Ordering::Relaxed)
                                    && available >= prefill_target {
                                        playback_primed.store(true, Ordering::Relaxed);
                                        if !playback_prefill_logged.swap(true, Ordering::Relaxed)
                                        {
                                            info!(
                                                "Playback jitter buffer primed: queued={} bytes, target_quantum={} bytes",
                                                available, target_write
                                            );
                                        }
                                    }

                                if playback_primed.load(Ordering::Relaxed) {
                                    let readable = available
                                        .min(target_write)
                                        .saturating_sub(available.min(target_write) % OUTPUT_FRAME_BYTES);

                                    if readable == 0 {
                                        // Lost headroom; fall back to silence and re-prime.
                                        playback_primed.store(false, Ordering::Relaxed);
                                    } else if let Ok(chunk) = consumer.read_chunk(readable) {
                                        for (i, byte) in chunk.into_iter().enumerate() {
                                            raw_data[i] = byte;
                                        }
                                    }
                                }
                            }
                            (target_write, false)
                        };

                        let chunk = datas[0].chunk_mut();
                        *chunk.offset_mut() = 0;
                        *chunk.stride_mut() = OUTPUT_FRAME_BYTES as i32;
                        *chunk.size_mut() = to_write as u32;


                    }
                },
            )
            .register()?;

            let playback_format_bytes =
                build_audio_raw_format_param(AudioFormat::S16LE, OUTPUT_CHANNELS as u32)?;
            let playback_format_pod = pw::spa::pod::Pod::from_bytes(&playback_format_bytes)
                .ok_or_else(|| anyhow!("Failed to parse playback format pod bytes"))?;
            let mut playback_params = [playback_format_pod];
            // Connect Playback Stream
            playback_stream.connect(
                Direction::Output,
                playback_target.connect_target_id,
                StreamFlags::MAP_BUFFERS | StreamFlags::RT_PROCESS | StreamFlags::AUTOCONNECT,
                &mut playback_params,
            )?;

            info!("PipeWire playback stream connected (Server Node).");
            _playback_stream_handle = Some(playback_stream);
            _playback_listener_handle = Some(playback_listener);
        }
    }

    info!("PipeWire loop running. Press Ctrl+C to stop.");

    // Timer to check running
    let loop_ = mainloop.loop_();
    let mainloop_clone = mainloop.clone();
    let _timer = loop_.add_timer(move |_| {
        if !running.load(Ordering::Relaxed) {
            mainloop_clone.quit();
        }
    });

    // Arm timer (timeout in ms)
    _timer
        .update_timer(
            Some(Duration::from_millis(100)),
            Some(Duration::from_millis(100)),
        )
        .into_result()?;

    mainloop.run();

    Ok(())
}
