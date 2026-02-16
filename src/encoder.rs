use anyhow::{anyhow, Context, Result};
use log::{error, info, warn};
use rtrb::{Consumer, Producer};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct EncoderConfig {
    pub ffmpeg_thread_queue_size: usize,
    pub feeder_chunk_frames: usize,
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            ffmpeg_thread_queue_size: 128,
            feeder_chunk_frames: 128,
        }
    }
}

/// Manages the FFmpeg subprocess for encoding.
///
/// Spawns `ffmpeg`, creates one thread to feed it audio from `input_consumer`,
/// and another thread to read encoded audio into `output_producer`.
///
/// # Arguments
///
/// * `input` - Consumer for raw F32 PCM (6 channels).
/// * `output` - Producer for encoded IEC61937 bytes.
/// * `running` - Atomic flag.
pub fn run_encoder_loop(
    input: Consumer<f32>,
    output: Producer<u8>,
    running: Arc<AtomicBool>,
) -> Result<()> {
    run_encoder_loop_with_config(input, output, running, EncoderConfig::default())
}

pub fn run_encoder_loop_with_config(
    mut input: Consumer<f32>,
    mut output: Producer<u8>,
    running: Arc<AtomicBool>,
    config: EncoderConfig,
) -> Result<()> {
    info!("Starting FFmpeg subprocess...");

    let ffmpeg_thread_queue_size = config.ffmpeg_thread_queue_size.max(1);
    let feeder_chunk_frames = config.feeder_chunk_frames.max(1);
    let ffmpeg_thread_queue_size_arg = ffmpeg_thread_queue_size.to_string();

    // Command:
    // ffmpeg -y -f f32le -ar 48000 -ac 6 -i pipe:0 -c:ac3 -b:a 640k -f spdif pipe:1
    // -f spdif handles the IEC61937 encapsulation for us!
    // Usually spdif output is S16LE (2 channels) carrying the payload.
    // The byte stream from stdout will be S16LE PCM frames essentially.

    let mut child = Command::new("ffmpeg")
        .args([
            "-y",
            "-f",
            "f32le",
            "-ar",
            "48000",
            "-ac",
            "6",
            "-i",
            "pipe:0", // Read from stdin
            "-c:a",
            "ac3",
            "-b:a",
            "640k", // Max bitrate for AC-3
            "-f",
            "spdif", // Encapsulate as IEC 61937
            "-fflags",
            "+nobuffer", // Reduce latency
            "-flags",
            "+low_delay", // Reduce latency
            "-probesize",
            "32", // Minimum probe size
            "-analyzeduration",
            "0", // No analysis duration
            "-flush_packets",
            "1", // Flush packets immediately
            "-avioflags",
            "direct", // Force direct IO
            "-thread_queue_size",
            ffmpeg_thread_queue_size_arg.as_str(),
            "pipe:1", // Write to stdout
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit()) // Let ffmpeg logs show up in stderr
        .spawn()
        .context("Failed to spawn ffmpeg")?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("Failed to open stdin"))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("Failed to open stdout"))?;

    let running_feeder = running.clone();

    // Spawn Feeder Thread (RingBuffer -> Stdin)
    let feeder_handle = thread::spawn(move || -> Result<()> {
        let mut byte_buffer = Vec::with_capacity(feeder_chunk_frames * 6 * 4);

        while running_feeder.load(Ordering::Relaxed) {
            // Read from RingBuffer
            // We want to move data as fast as possible.
            if input.slots() > 0 {
                if let Ok(chunk) = input.read_chunk(input.slots().min(feeder_chunk_frames * 6)) {
                    // Copy to local buffer
                    byte_buffer.clear();
                    for sample in chunk {
                        // Convert f32 to bytes (le)
                        byte_buffer.extend_from_slice(&sample.to_le_bytes());
                    }

                    // Write to stdin
                    if let Err(e) = stdin.write_all(&byte_buffer) {
                        if running_feeder.load(Ordering::Relaxed) {
                            return Err(anyhow!(e).context("Failed to write to ffmpeg stdin"));
                        }
                        break;
                    }
                    // Force flush to prevent buffering in the pipe
                    if let Err(e) = stdin.flush() {
                        if running_feeder.load(Ordering::Relaxed) {
                            return Err(anyhow!(e).context("Failed to flush ffmpeg stdin"));
                        }
                        break;
                    }
                } else {
                    thread::sleep(Duration::from_millis(1));
                }
            } else {
                thread::sleep(Duration::from_millis(1));
            }
        }

        Ok(())
    });

    // Run Reader Loop (Stdout -> RingBuffer) in this thread
    let mut read_buffer = [0u8; 4096];
    let mut reader_error: Option<anyhow::Error> = None;

    loop {
        // Read from stdout
        match stdout.read(&mut read_buffer) {
            Ok(0) => {
                if running.load(Ordering::Relaxed) {
                    warn!("FFmpeg stdout closed unexpectedly.");
                    reader_error = Some(anyhow!("FFmpeg stdout closed unexpectedly"));
                }
                break;
            }
            Ok(n) => {
                // Write to RingBuffer
                // We need to write all `n` bytes.
                let mut bytes_written = 0;
                let mut abort_due_to_shutdown_backpressure = false;
                while bytes_written < n {
                    if output.slots() > 0 {
                        let request = (n - bytes_written).min(output.slots());
                        match output.write_chunk_uninit(request) {
                            Ok(chunk) => {
                                let to_write = chunk.len();
                                chunk.fill_from_iter(
                                    read_buffer[bytes_written..bytes_written + to_write]
                                        .iter()
                                        .copied(),
                                );
                                bytes_written += to_write;
                            }
                            Err(_) => {
                                // Full
                                if !running.load(Ordering::Relaxed) {
                                    abort_due_to_shutdown_backpressure = true;
                                    break;
                                }
                                thread::sleep(Duration::from_micros(100));
                            }
                        }
                    } else {
                        if !running.load(Ordering::Relaxed) {
                            abort_due_to_shutdown_backpressure = true;
                            break;
                        }
                        thread::sleep(Duration::from_millis(1));
                    }
                }

                if abort_due_to_shutdown_backpressure {
                    break;
                }
            }
            Err(e) => {
                if running.load(Ordering::Relaxed) {
                    error!("Error reading ffmpeg stdout: {}", e);
                    reader_error = Some(anyhow!(e).context("Error reading ffmpeg stdout"));
                }
                break;
            }
        }
    }

    info!("Stopping ffmpeg...");
    match feeder_handle.join() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            if reader_error.is_none() {
                reader_error = Some(e);
            }
        }
        Err(e) => {
            if reader_error.is_none() {
                reader_error = Some(anyhow!("Encoder feeder thread panicked: {:?}", e));
            }
        }
    }

    let deadline = Instant::now() + Duration::from_millis(500);
    let mut forced_kill = false;
    let child_status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    forced_kill = true;
                    let _ = child.kill();
                    break child.wait().ok();
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(e) => {
                if reader_error.is_none() {
                    reader_error =
                        Some(anyhow!(e).context("Failed to query ffmpeg process status"));
                }
                forced_kill = true;
                let _ = child.kill();
                break child.wait().ok();
            }
        }
    };

    if running.load(Ordering::Relaxed) {
        if let Some(err) = reader_error {
            return Err(err);
        }
        if forced_kill {
            return Err(anyhow!(
                "FFmpeg process did not terminate in time and was killed"
            ));
        }
        if let Some(status) = child_status {
            if !status.success() {
                return Err(anyhow!("FFmpeg exited with status: {status}"));
            }
        }
    }

    Ok(())
}
