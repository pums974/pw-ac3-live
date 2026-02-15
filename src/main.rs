use anyhow::{Context, Result};
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

    /// Ring buffer capacity in audio frames (samples per channel)
    /// Default is approx 100ms at 48kHz
    #[arg(short, long, default_value_t = 4800)]
    buffer_size: usize,
}

fn main() -> Result<()> {
    env_logger::init();
    let args = Args::parse();

    info!("Starting pw-ac3-live...");
    info!("Target Sink: {:?}", args.target);
    info!("Buffer Size: {}", args.buffer_size);

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
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(capacity_samples * 4); // ample space

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
    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // 4. Start PipeWire Client (Main Thread or blocked)
    // logic to connect to PipeWire...
    pipewire_client::run_pipewire_loop(input_producer, output_consumer, args.target, running)?;

    // Wait for encoder to finish if it hasn't already
    if let Err(e) = encoder_handle.join() {
        warn!("Encoder thread panicked: {:?}", e);
    }

    info!("Exiting.");
    Ok(())
}
