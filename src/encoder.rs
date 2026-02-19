use anyhow::{anyhow, Context, Result};
use log::{error, info, warn};
use rtrb::{Consumer, Producer};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
use std::os::unix::io::AsRawFd;

const INPUT_CHANNELS: usize = 6;

const OUTPUT_FRAME_BYTES_U8: usize = 4;
const MAX_STDOUT_READ_BUFFER_SIZE: usize = 1024;
const MIN_STDOUT_READ_BUFFER_SIZE: usize = 512;

/// Minimum pipe buffer size (4KB = one page, the kernel minimum).
const TARGET_PIPE_SIZE: i32 = 4096;

/// Shrink a pipe's kernel buffer to `TARGET_PIPE_SIZE` bytes.
/// Returns `Ok(actual_size)` on success. Failures are non-fatal.
#[cfg(target_os = "linux")]
fn shrink_pipe_buffer(fd: std::os::unix::io::RawFd, label: &str) {
    const F_SETPIPE_SZ: libc::c_int = 1031;
    const F_GETPIPE_SZ: libc::c_int = 1032;

    let old_size = unsafe { libc::fcntl(fd, F_GETPIPE_SZ) };
    let ret = unsafe { libc::fcntl(fd, F_SETPIPE_SZ, TARGET_PIPE_SIZE) };
    if ret < 0 {
        warn!(
            "Could not shrink {} pipe (fd={}) from {} to {}: errno={}",
            label,
            fd,
            old_size,
            TARGET_PIPE_SIZE,
            std::io::Error::last_os_error()
        );
    } else {
        info!(
            "Shrunk {} pipe (fd={}) from {} to {} bytes",
            label, fd, old_size, ret
        );
    }
}

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

    let mut command = Command::new("ffmpeg");

    // Global / Demuxer Flags MUST come before input
    command.args([
        "-y",
        "-probesize",
        "32",
        "-analyzeduration",
        "0",
        "-fflags",
        "+nobuffer",
        "-flags",
        "+low_delay",
        // Input Format
        "-f",
        "f32le",
        "-ar",
        "48000",
        "-ac",
        "6",
        "-thread_queue_size",
        ffmpeg_thread_queue_size_arg.as_str(),
        "-i",
        "pipe:0", // Input
    ]);

    command.args([
        "-c:a", "ac3", "-b:a", "640k", "-bufsize", "0", "-f", "spdif",
    ]);

    // Muxer / Output flags
    command.args([
        "-flush_packets",
        "1",
        "-muxdelay",
        "0",
        "-muxpreload",
        "0",
        "-avioflags",
        "direct",
        "pipe:1", // Output
    ]);

    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit()); // Let ffmpeg logs show up in stderr

    let mut child = command.spawn().context("Failed to spawn ffmpeg")?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("Failed to open stdin"))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("Failed to open stdout"))?;

    // Shrink the kernel pipe buffers between us and FFmpeg to reduce latency.
    // Default is 64KB per pipe; we shrink to 4KB (one page).
    #[cfg(target_os = "linux")]
    {
        shrink_pipe_buffer(stdin.as_raw_fd(), "ffmpeg-stdin");
        shrink_pipe_buffer(stdout.as_raw_fd(), "ffmpeg-stdout");
    }

    let running_feeder = running.clone();
    let output_capacity = output.slots();
    // Keep read chunks small enough to avoid bursty output->playback pressure.
    let mut stdout_read_buffer_size =
        (output_capacity / 8).clamp(MIN_STDOUT_READ_BUFFER_SIZE, MAX_STDOUT_READ_BUFFER_SIZE);
    stdout_read_buffer_size -= stdout_read_buffer_size % OUTPUT_FRAME_BYTES_U8;
    if stdout_read_buffer_size == 0 {
        stdout_read_buffer_size = OUTPUT_FRAME_BYTES_U8;
    }
    info!(
        "FFmpeg stdout read chunk size: {} bytes (output ring capacity: {} bytes)",
        stdout_read_buffer_size, output_capacity
    );

    // Spawn Feeder Thread (RingBuffer -> Stdin)
    let feeder_handle = thread::spawn(move || -> Result<()> {
        let mut byte_buffer = Vec::with_capacity(feeder_chunk_frames * INPUT_CHANNELS * 4);

        while running_feeder.load(Ordering::Relaxed) {
            // Read from RingBuffer
            // We want to move data as fast as possible.
            let readable_samples = input.slots();
            if readable_samples > 0 {
                if let Ok(chunk) =
                    input.read_chunk(readable_samples.min(feeder_chunk_frames * INPUT_CHANNELS))
                {
                    // Copy to local buffer
                    byte_buffer.clear();
                    for sample in chunk {
                        // Convert f32 to bytes (le)
                        byte_buffer.extend_from_slice(&sample.to_le_bytes());
                    }

                    // Write to stdin
                    if let Err(e) = stdin.write_all(&byte_buffer) {
                        if running_feeder.load(Ordering::Relaxed) {
                            return Err(
                                anyhow::Error::new(e).context("Failed to write to ffmpeg stdin")
                            );
                        }
                        break;
                    }
                    // Force flush to prevent buffering in the pipe
                    if let Err(e) = stdin.flush() {
                        if running_feeder.load(Ordering::Relaxed) {
                            return Err(
                                anyhow::Error::new(e).context("Failed to flush ffmpeg stdin")
                            );
                        }
                        break;
                    }
                } else {
                    thread::sleep(Duration::from_micros(250));
                }
            } else {
                thread::sleep(Duration::from_micros(250));
            }
        }

        Ok(())
    });

    // Run Reader Loop (Stdout -> RingBuffer) in this thread
    let mut read_buffer = vec![0u8; stdout_read_buffer_size];
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
                        thread::sleep(Duration::from_micros(250));
                    }
                }

                if abort_due_to_shutdown_backpressure {
                    break;
                }
            }
            Err(e) => {
                if running.load(Ordering::Relaxed) {
                    error!("Error reading ffmpeg stdout: {}", e);
                    reader_error =
                        Some(anyhow::Error::new(e).context("Error reading ffmpeg stdout"));
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
    let child_status: Option<std::process::ExitStatus> = loop {
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
                    reader_error = Some(
                        anyhow::Error::new(e).context("Failed to query ffmpeg process status"),
                    );
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
