use anyhow::{anyhow, Context, Result};
use clap::Parser;
use log::{info, warn};
use rtrb::RingBuffer;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

// Module declarations
use pw_ac3_live::encoder;
use pw_ac3_live::pipewire_client;

/// AC-3 Real-time Encoder for PipeWire
///
/// Captures 6-channel PCM audio, encodes it to AC-3, and outputs it to a hardware sink.
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    /// Target PipeWire Node ID or Name for playback (the HDMI sink)
    #[arg(short, long)]
    target: Option<String>,

    /// Output to stdout instead of PipeWire playback
    #[arg(long, action)]
    stdout: bool,

    /// Ring buffer capacity in audio frames (samples per channel)
    /// Default is approx 100ms at 48kHz
    #[arg(short, long, default_value_t = 4800)]
    buffer_size: usize,

    /// Output ring buffer capacity in audio frames (2ch S16LE playback stream)
    /// Defaults to --buffer-size when omitted.
    #[arg(long)]
    output_buffer_size: Option<usize>,

    /// Requested PipeWire node latency (e.g. 64/48000, 32/48000, 16/48000)
    #[arg(long, default_value = "64/48000")]
    latency: String,

    /// FFmpeg input thread queue size
    #[arg(long, default_value_t = 128)]
    ffmpeg_thread_queue_size: usize,

    /// Number of interleaved frames pushed to FFmpeg per write
    #[arg(long, default_value_t = 128)]
    ffmpeg_chunk_frames: usize,
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    info!("Starting pw-ac3-live...");
    info!("Target Sink: {:?}", args.target);
    info!("Buffer Size: {}", args.buffer_size);
    info!(
        "Output Buffer Size: {}",
        args.output_buffer_size.unwrap_or(args.buffer_size)
    );
    info!("PipeWire node latency: {}", args.latency);
    info!(
        "FFmpeg queue/chunk: {} / {}",
        args.ffmpeg_thread_queue_size, args.ffmpeg_chunk_frames
    );

    // 1. Setup RingBuffers
    // SPSC (Single Producer Single Consumer) lock-free queues.
    // Input: Capture -> Encoder (f32 samples)
    // We need 6 channels. For simplicity, let's say the ring buffer stores interleaved f32,
    // or we use a single ring buffer of `Vec<f32>` (bad for RT) or flat f32 array.
    //
    // Optimization: A flat Buffer of f32 is best.
    // Capacity = frames * channels.
    let capacity_samples = args.buffer_size * 6;
    let (input_producer, input_consumer) = RingBuffer::<f32>::new(capacity_samples);

    // Output: Encoder -> Playback (u8 bytes for IEC61937 stream)
    // AC-3 frames are small, but IEC61937 frames match the PCM rate.
    // Allocating enough for output buffering.
    let output_buffer_size_frames = args.output_buffer_size.unwrap_or(args.buffer_size).max(1);
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(output_buffer_size_frames * 4);

    // 2. Setup Shutdown Signal
    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();
    ctrlc::set_handler(move || {
        warn!("Received Ctrl-C, shutting down...");
        r.store(false, Ordering::SeqCst);
    })
    .context("Error setting Ctrl-C handler")?;

    // 3. Spawn Encoder Thread
    let encoder_running = running.clone();
    let encoder_config = encoder::EncoderConfig {
        ffmpeg_thread_queue_size: args.ffmpeg_thread_queue_size,
        feeder_chunk_frames: args.ffmpeg_chunk_frames,
    };
    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop_with_config(
            input_consumer,
            output_producer,
            encoder_running,
            encoder_config,
        )
    });

    // 4. Start PipeWire Client (Main Thread or blocked)
    // logic to connect to PipeWire...
    let pipewire_config = pipewire_client::PipewireConfig {
        node_latency: args.latency,
    };
    let pipewire_result = pipewire_client::run_pipewire_loop_with_config(
        input_producer,
        output_consumer,
        args.target,
        args.stdout,
        running.clone(),
        pipewire_config,
    );

    // Always request shutdown and join the encoder thread, even if PipeWire init failed.
    running.store(false, Ordering::SeqCst);

    let encoder_result = match encoder_handle.join() {
        Ok(result) => result,
        Err(e) => Err(anyhow!("Encoder thread panicked: {e:?}")),
    };

    if let Err(e) = pipewire_result {
        if let Err(encoder_err) = encoder_result {
            return Err(e).context(format!(
                "Encoder also failed while handling PipeWire failure: {encoder_err:#}"
            ));
        }
        return Err(e);
    }

    if let Err(e) = encoder_result {
        return Err(e).context("Encoder loop failed");
    }

    info!("Exiting.");
    Ok(())
}
