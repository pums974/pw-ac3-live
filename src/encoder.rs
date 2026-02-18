use anyhow::{anyhow, Context, Result};
use log::{error, info, warn};
use rtrb::{Consumer, Producer};
use std::cmp::Ordering as CmpOrdering;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const INPUT_CHANNELS: usize = 6;
const SAMPLE_RATE_HZ: f64 = 48_000.0;
const OUTPUT_FRAME_BYTES: f64 = 4.0;
const OUTPUT_FRAME_BYTES_U8: usize = 4;
const MAX_STDOUT_READ_BUFFER_SIZE: usize = 1024;
const MIN_STDOUT_READ_BUFFER_SIZE: usize = 512;
const PROFILE_REPORT_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Debug, Clone)]
pub struct EncoderConfig {
    pub ffmpeg_thread_queue_size: usize,
    pub feeder_chunk_frames: usize,
    pub profile_latency: bool,
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            ffmpeg_thread_queue_size: 128,
            feeder_chunk_frames: 128,
            profile_latency: false,
        }
    }
}

#[derive(Default)]
struct EncoderProfileWindow {
    feeder_batch_ms: Vec<f64>,
    feeder_queue_ms: Vec<f64>,
    stdin_io_ms: Vec<f64>,
    stdout_read_wait_ms: Vec<f64>,
    output_queue_ms: Vec<f64>,
    output_backpressure_ms: Vec<f64>,
}

#[derive(Default)]
struct EncoderLatencyProfiler {
    window: Mutex<EncoderProfileWindow>,
}

#[derive(Clone, Copy)]
struct MetricSummary {
    count: usize,
    avg_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
    max_ms: f64,
}

impl EncoderLatencyProfiler {
    fn record_feeder(&self, feeder_batch_ms: f64, feeder_queue_ms: f64, stdin_io_ms: f64) {
        if let Ok(mut window) = self.window.try_lock() {
            window.feeder_batch_ms.push(feeder_batch_ms);
            window.feeder_queue_ms.push(feeder_queue_ms);
            window.stdin_io_ms.push(stdin_io_ms);
        }
    }

    fn record_reader(
        &self,
        stdout_read_wait_ms: f64,
        output_queue_ms: f64,
        output_backpressure_ms: f64,
    ) {
        if let Ok(mut window) = self.window.try_lock() {
            window.stdout_read_wait_ms.push(stdout_read_wait_ms);
            window.output_queue_ms.push(output_queue_ms);
            window.output_backpressure_ms.push(output_backpressure_ms);
        }
    }

    fn snapshot(&self) -> Option<EncoderProfileWindow> {
        let mut window = self.window.lock().ok()?;
        let is_empty = window.feeder_batch_ms.is_empty()
            && window.feeder_queue_ms.is_empty()
            && window.stdin_io_ms.is_empty()
            && window.stdout_read_wait_ms.is_empty()
            && window.output_queue_ms.is_empty()
            && window.output_backpressure_ms.is_empty();
        if is_empty {
            return None;
        }
        Some(std::mem::take(&mut *window))
    }
}

fn summarize_ms(values: &mut [f64]) -> Option<MetricSummary> {
    if values.is_empty() {
        return None;
    }

    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(CmpOrdering::Equal));

    let count = values.len();
    let sum: f64 = values.iter().sum();
    let avg_ms = sum / (count as f64);
    let p50_idx = ((count - 1) * 50) / 100;
    let p95_idx = ((count - 1) * 95) / 100;

    Some(MetricSummary {
        count,
        avg_ms,
        p50_ms: values[p50_idx],
        p95_ms: values[p95_idx],
        max_ms: *values.last().unwrap_or(&0.0),
    })
}

fn log_encoder_profile_snapshot(profiler: &EncoderLatencyProfiler) {
    let Some(mut window) = profiler.snapshot() else {
        return;
    };

    let metrics = [
        ("feeder.batch_ms", &mut window.feeder_batch_ms),
        ("feeder.queue_delay_ms", &mut window.feeder_queue_ms),
        ("feeder.stdin_io_ms", &mut window.stdin_io_ms),
        ("reader.stdout_wait_ms", &mut window.stdout_read_wait_ms),
        ("reader.output_queue_delay_ms", &mut window.output_queue_ms),
        (
            "reader.output_backpressure_ms",
            &mut window.output_backpressure_ms,
        ),
    ];

    for (name, values) in metrics {
        if let Some(summary) = summarize_ms(values.as_mut_slice()) {
            info!(
                "latency[encoder] {} n={} avg={:.2} p50={:.2} p95={:.2} max={:.2}",
                name, summary.count, summary.avg_ms, summary.p50_ms, summary.p95_ms, summary.max_ms
            );
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
    let profile_latency = config.profile_latency;
    let ffmpeg_thread_queue_size_arg = ffmpeg_thread_queue_size.to_string();
    let profiler = profile_latency.then(|| Arc::new(EncoderLatencyProfiler::default()));
    let profile_reporter_running = Arc::new(AtomicBool::new(true));

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
    let profiler_feeder = profiler.clone();
    let profiler_reader = profiler.clone();
    let output_capacity = output.slots();
    // Keep read chunks small enough to avoid bursty output->playback pressure.
    let mut stdout_read_buffer_size = (output_capacity / 8)
        .clamp(MIN_STDOUT_READ_BUFFER_SIZE, MAX_STDOUT_READ_BUFFER_SIZE);
    stdout_read_buffer_size -= stdout_read_buffer_size % OUTPUT_FRAME_BYTES_U8;
    if stdout_read_buffer_size == 0 {
        stdout_read_buffer_size = OUTPUT_FRAME_BYTES_U8;
    }
    info!(
        "FFmpeg stdout read chunk size: {} bytes (output ring capacity: {} bytes)",
        stdout_read_buffer_size, output_capacity
    );

    let profile_reporter_handle = profiler.as_ref().map(|profiler| {
        let reporter_running = profile_reporter_running.clone();
        let profiler = profiler.clone();
        thread::spawn(move || {
            while reporter_running.load(Ordering::Relaxed) {
                thread::sleep(PROFILE_REPORT_INTERVAL);
                log_encoder_profile_snapshot(&profiler);
            }
            log_encoder_profile_snapshot(&profiler);
        })
    });

    // Spawn Feeder Thread (RingBuffer -> Stdin)
    let feeder_handle = thread::spawn(move || -> Result<()> {
        let mut byte_buffer = Vec::with_capacity(feeder_chunk_frames * INPUT_CHANNELS * 4);

        while running_feeder.load(Ordering::Relaxed) {
            // Read from RingBuffer
            // We want to move data as fast as possible.
            let readable_samples = input.slots();
            if readable_samples > 0 {
                let feeder_queue_delay_ms =
                    (readable_samples as f64 / (INPUT_CHANNELS as f64 * SAMPLE_RATE_HZ)) * 1000.0;
                if let Ok(chunk) =
                    input.read_chunk(readable_samples.min(feeder_chunk_frames * INPUT_CHANNELS))
                {
                    let feeder_batch_started = Instant::now();
                    // Copy to local buffer
                    byte_buffer.clear();
                    for sample in chunk {
                        // Convert f32 to bytes (le)
                        byte_buffer.extend_from_slice(&sample.to_le_bytes());
                    }

                    // Write to stdin
                    let stdin_io_started = Instant::now();
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

                    if let Some(profiler) = profiler_feeder.as_ref() {
                        profiler.record_feeder(
                            feeder_batch_started.elapsed().as_secs_f64() * 1000.0,
                            feeder_queue_delay_ms,
                            stdin_io_started.elapsed().as_secs_f64() * 1000.0,
                        );
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
        let stdout_read_started = Instant::now();
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
                let output_readable = output_capacity.saturating_sub(output.slots());
                let output_queue_delay_ms =
                    (output_readable as f64 / (OUTPUT_FRAME_BYTES * SAMPLE_RATE_HZ)) * 1000.0;
                let mut backpressure_delay_ms = 0.0;
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
                                backpressure_delay_ms += 0.1;
                            }
                        }
                    } else {
                        if !running.load(Ordering::Relaxed) {
                            abort_due_to_shutdown_backpressure = true;
                            break;
                        }
                        thread::sleep(Duration::from_micros(250));
                        backpressure_delay_ms += 0.25;
                    }
                }

                if let Some(profiler) = profiler_reader.as_ref() {
                    profiler.record_reader(
                        stdout_read_started.elapsed().as_secs_f64() * 1000.0,
                        output_queue_delay_ms,
                        backpressure_delay_ms,
                    );
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

    profile_reporter_running.store(false, Ordering::Relaxed);
    if let Some(handle) = profile_reporter_handle {
        let _ = handle.join();
    }

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
