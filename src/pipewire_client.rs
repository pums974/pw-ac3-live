use anyhow::Result;
use log::info;
use pipewire as pw;
use pipewire::main_loop::MainLoop;
use pipewire::properties::properties;
use pipewire::spa::utils::Direction; // Correct import for Direction
use pipewire::stream::{StreamFlags, StreamRef};
use rtrb::{Consumer, Producer};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
// use pipewire::context::Context; // Avoid trait conflict, use qualified path

/// Runs the main PipeWire event loop.
pub fn run_pipewire_loop(
    input_producer: Producer<f32>,
    output_consumer: Consumer<u8>,
    _target_node: Option<String>,
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
        "audio.channels" => "6",
        "audio.position" => "FL,FR,FC,LFE,RL,RR",
        "audio.rate" => "48000",
        "audio.format" => "F32LE",
    };

    let data = Arc::new(Mutex::new(input_producer));

    // Create stream first
    let capture_stream = pw::stream::Stream::new(&core, "ac3-encoder-capture", props)?;

    // Add listener for process callback
    let _capture_listener = capture_stream
        .add_local_listener::<()>()
        .state_changed(|_stream, _data, old, new| {
            info!("Capture Stream state changed: {:?} -> {:?}", old, new);
        })
        .process(move |stream: &StreamRef, _data| {
            match stream.dequeue_buffer() {
                None => (),
                Some(mut buffer) => {
                    let datas = buffer.datas_mut();
                    if datas.is_empty() {
                        return;
                    }

                    let chunk = datas[0].chunk();
                    let offset = chunk.offset() as usize;
                    let size = chunk.size() as usize;

                    if let Some(raw_data) = datas[0].data() {
                        if offset + size <= raw_data.len() {
                            let data_slice = &raw_data[offset..offset + size];

                            // Check alignment (F32 = 4 bytes)
                            if data_slice.len() % 4 == 0 {
                                let f32_samples = unsafe {
                                    std::slice::from_raw_parts(
                                        data_slice.as_ptr() as *const f32,
                                        data_slice.len() / 4,
                                    )
                                };

                                if let Ok(mut producer) = data.try_lock() {
                                    match producer.write_chunk_uninit(f32_samples.len()) {
                                        Ok(chunk) => {
                                            chunk.fill_from_iter(f32_samples.iter().copied());
                                        }
                                        Err(_) => {
                                            // RingBuffer full
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        })
        .register()?;

    // Connect Capture Stream
    // Connect Capture Stream
    capture_stream.connect(
        Direction::Input,
        None,
        StreamFlags::MAP_BUFFERS | StreamFlags::RT_PROCESS,
        &mut [],
    )?;

    info!("PipeWire capture stream connected.");

    // ------------------------------------------------------------------
    // 2. Create Playback Stream (Output to HDMI)
    // ------------------------------------------------------------------
    // Note: Do NOT set MEDIA_CLASS. We want to be a client stream that connects to a sink.
    let mut playback_props = properties! {
        *pw::keys::NODE_NAME => "pw-ac3-live-output",
        *pw::keys::NODE_DESCRIPTION => "AC-3 Live Output",
        *pw::keys::APP_NAME => "pw-ac3-live",
        "audio.channels" => "2",
        "audio.rate" => "48000",
        "audio.format" => "S16LE",
        "stream.capture.sink" => "true", // Try to be helpful identifying this stream
    };

    // If a target is specified, connect to it.
    if let Some(target) = _target_node {
        playback_props.insert("target.object", target);
    }

    let output_data = Arc::new(Mutex::new(output_consumer));

    // Create stream
    let playback_stream = pw::stream::Stream::new(&core, "ac3-encoder-playback", playback_props)?;

    // Add listener
    let _playback_listener = playback_stream
        .add_local_listener::<()>()
        .state_changed(|_stream, _data, old, new| {
            info!("Playback Stream state changed: {:?} -> {:?}", old, new);
        })
        .process(move |stream: &StreamRef, _data| {
            match stream.dequeue_buffer() {
                None => (),
                Some(mut buffer) => {
                    let datas = buffer.datas_mut();
                    if datas.is_empty() {
                        return;
                    }

                    if let Some(raw_data) = datas[0].data() {
                        let capacity = raw_data.len();

                        if let Ok(mut consumer) = output_data.try_lock() {
                            let available = consumer.slots();
                            let to_write = available.min(capacity);

                            if to_write > 0 {
                                if let Ok(chunk) = consumer.read_chunk(to_write) {
                                    // Use into_iter for ReadChunk
                                    for (i, byte) in chunk.into_iter().enumerate() {
                                        raw_data[i] = byte;
                                    }

                                    // Set Chunk fields directly
                                    *datas[0].chunk_mut().offset_mut() = 0;
                                    *datas[0].chunk_mut().stride_mut() = 4; // S16LE stereo = 4 bytes frame
                                    *datas[0].chunk_mut().size_mut() = to_write as u32;
                                }
                            } else {
                                for byte in raw_data.iter_mut().take(capacity) {
                                    *byte = 0;
                                }
                                *datas[0].chunk_mut().size_mut() = capacity as u32;
                            }
                        }
                    }
                }
            }
        })
        .register()?;

    // Connect Playback Stream
    playback_stream.connect(
        Direction::Output,
        None,
        StreamFlags::MAP_BUFFERS | StreamFlags::RT_PROCESS,
        &mut [],
    )?;

    info!("PipeWire playback stream connected.");

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
