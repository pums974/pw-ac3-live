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

const INPUT_CHANNELS: usize = 6;
const OUTPUT_CHANNELS: usize = 2;
const SAMPLE_RATE: &str = "48000";
const SAMPLE_RATE_HZ: u32 = 48_000;
const STDOUT_READ_BUFFER_SIZE: usize = 4096;
const OUTPUT_FRAME_BYTES: usize = OUTPUT_CHANNELS * size_of::<i16>();

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
    let mut playback_props = properties! {
        *pw::keys::MEDIA_CLASS => "Audio/Source",
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
        "node.autoconnect" => "true",
    };

    if let Some(target_object) = target.target_object.as_deref() {
        // Works with both node names and numeric object IDs.
        playback_props.insert("target.object", target_object);
    }

    playback_props
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

fn build_audio_raw_format_param(format: AudioFormat, channels: u32) -> Result<Vec<u8>> {
    let mut audio_info = AudioInfoRaw::new();
    audio_info.set_format(format);
    audio_info.set_rate(SAMPLE_RATE_HZ);
    audio_info.set_channels(channels);

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
    mut output_consumer: Consumer<u8>,
    target_node: Option<String>,
    use_stdout: bool,
    running: Arc<AtomicBool>,
) -> Result<()> {
    info!("Initializing PipeWire client...");

    pw::init();

    let mainloop = MainLoop::new(None)?;
    let context = pw::context::Context::new(&mainloop)?;
    let core = context.connect(None)?;

    // ------------------------------------------------------------------
    // 1. Create Capture Stream (Virtual Sink)
    // ------------------------------------------------------------------

    let props = properties! {
        *pw::keys::MEDIA_CLASS => "Audio/Sink",
        *pw::keys::NODE_NAME => "pw-ac3-live-input",
        *pw::keys::NODE_DESCRIPTION => "AC-3 Encoder Input",
        *pw::keys::APP_NAME => "pw-ac3-live",
        "audio.channels" => INPUT_CHANNELS.to_string(),
        "audio.position" => "FL,FR,FC,LFE,SL,SR",
        "audio.rate" => SAMPLE_RATE,
        "audio.format" => "F32LE",
    };

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
                        if frame_aligned_writable == 0 {
                            return;
                        }

                        if let Ok(chunk) = producer.write_chunk_uninit(frame_aligned_writable) {
                            chunk.fill_from_iter(
                                interleaved_scratch
                                    .iter()
                                    .take(frame_aligned_writable)
                                    .copied(),
                            );
                        }
                    }
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

    if use_stdout {
        // Spawn a thread to read from ring buffer and write to stdout
        let running_clone = running.clone();
        thread::spawn(move || {
            let mut stdout = std::io::stdout().lock();
            if let Err(e) =
                run_stdout_output_loop(&mut output_consumer, running_clone.as_ref(), &mut stdout)
            {
                log::error!("Failed to write to stdout: {}", e);
            }
        });
        info!("Outputting to stdout (playback stream disabled).");
        _playback_stream_handle = None;
        _playback_listener_handle = None;
    } else {
        // Create Playback Stream (Output to HDMI/Sink)

        // Strategy: Use properties for Audio/Source
        let playback_props = build_playback_properties(&playback_target);

        let output_data = Arc::new(Mutex::new(output_consumer));

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

                        let capacity = {
                            let Some(raw_data) = datas[0].data() else {
                                return;
                            };
                            let capacity = raw_data.len();
                            if capacity == 0 {
                                return;
                            }

                            raw_data.fill(0);

                            if let Ok(mut consumer) = output_data.try_lock() {
                                let available = consumer.slots();
                                let to_write = (available.min(capacity) / OUTPUT_FRAME_BYTES)
                                    * OUTPUT_FRAME_BYTES;

                                if to_write > 0 {
                                    if let Ok(chunk) = consumer.read_chunk(to_write) {
                                        for (i, byte) in chunk.into_iter().enumerate() {
                                            raw_data[i] = byte;
                                        }
                                    }
                                }
                            }

                            capacity
                        };

                        let chunk = datas[0].chunk_mut();
                        *chunk.offset_mut() = 0;
                        *chunk.stride_mut() = OUTPUT_FRAME_BYTES as i32;
                        *chunk.size_mut() = capacity as u32;
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
