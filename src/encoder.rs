use anyhow::{anyhow, Context, Result};
use log::{error, info, warn};
use rtrb::{Consumer, Producer};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

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
    mut input: Consumer<f32>,
    mut output: Producer<u8>,
    running: Arc<AtomicBool>,
) -> Result<()> {
    info!("Starting FFmpeg subprocess...");

    // Command:
    // ffmpeg -y -f f32le -ar 48000 -ac 6 -i pipe:0 -c:ac3 -b:a 640k -f spdif pipe:1
    // -f spdif handles the IEC61937 encapsulation for us!
    // Usually spdif output is S16LE (2 channels) carrying the payload.
    // The byte stream from stdout will be S16LE PCM frames essentially.

    let mut child = Command::new("ffmpeg")
        .args([
            "-y", "-f", "f32le", "-ar", "48000", "-ac", "6", "-i",
            "pipe:0", // Read from stdin
            "-c:a", "ac3", "-b:a", "640k", // Max bitrate for AC-3
            "-f", "spdif",  // Encapsulate as IEC 61937
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
    let feeder_handle = thread::spawn(move || {
        let mut _buffer = vec![0.0f32; 1024 * 6]; // Chunk size
        let mut byte_buffer = Vec::with_capacity(1024 * 6 * 4);

        while running_feeder.load(Ordering::Relaxed) {
            // Read from RingBuffer
            // We want to move data as fast as possible.
            if input.slots() > 0 {
                if let Ok(chunk) = input.read_chunk(input.slots().min(1024 * 6)) {
                    // Copy to local buffer
                    byte_buffer.clear();
                    for sample in chunk {
                        // Convert f32 to bytes (le)
                        byte_buffer.extend_from_slice(&sample.to_le_bytes());
                    }

                    // Write to stdin
                    if let Err(e) = stdin.write_all(&byte_buffer) {
                        error!("Failed to write to ffmpeg stdin: {}", e);
                        break;
                    }
                } else {
                    thread::sleep(Duration::from_millis(1));
                }
            } else {
                thread::sleep(Duration::from_millis(1));
            }
        }
    });

    // Run Reader Loop (Stdout -> RingBuffer) in this thread
    let mut read_buffer = [0u8; 4096];

    loop {
        // Read from stdout
        match stdout.read(&mut read_buffer) {
            Ok(0) => {
                warn!("FFmpeg stdout closed unexpectedly.");
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
                error!("Error reading ffmpeg stdout: {}", e);
                break;
            }
        }
    }

    info!("Stopping ffmpeg...");
    let _ = feeder_handle.join();
    let deadline = Instant::now() + Duration::from_millis(500);
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
        }
    }

    Ok(())
}
