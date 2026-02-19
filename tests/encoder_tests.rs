use pw_ac3_live::encoder;
use rtrb::RingBuffer;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn test_encoder_throughput() {
    // 1. Setup RingBuffers
    // 6 channels * 48000 Hz * 1 second buffer (approx)
    let buffer_size = 48000 * 6;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    // 2. Spawn Encoder
    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // 3. Generate 1 second of silence (6 channels, 48kHz)
    let samples_to_write = 48000 * 6;
    let silence = vec![0.0f32; samples_to_write];

    let mut written = 0;
    while written < samples_to_write {
        let remaining = samples_to_write - written;
        let request = remaining.min(1024);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    // 4. Wait a bit for processing
    thread::sleep(Duration::from_millis(500));

    // 5. Signal stop
    running.store(false, Ordering::SeqCst);
    let _ = encoder_handle.join().unwrap();

    // 6. Verify Output
    // We expect *some* bytes. AC-3 at 640kbps is ~80KB/s.
    // 0.5s of audio should produce ~40KB.
    let available_bytes = output_consumer.slots();
    println!("Encoded bytes available: {}", available_bytes);

    assert!(available_bytes > 1000, "Encoder should have produced data");
}

#[test]
fn test_encoder_shutdown_cleanly() {
    let buffer_size = 48000 * 6;
    let (_, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, _) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // Stop immediately
    running.store(false, Ordering::SeqCst);

    // Should join quickly
    let result = encoder_handle.join();
    assert!(
        result.is_ok(),
        "Encoder thread panics on immediate shutdown"
    );
}

#[test]
fn test_encoder_stress() {
    // Run multiple instances to check resource contention (e.g. ffmpeg spawning)
    let mut handles = vec![];

    for _ in 0..5 {
        handles.push(thread::spawn(|| {
            let buffer_size = 48000 * 6;
            let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
            let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

            let running = Arc::new(AtomicBool::new(true));
            let encoder_running = running.clone();

            let t = thread::spawn(move || {
                encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
            });

            // Feed a little data
            let silence = vec![0.0f32; 48000]; // 1/6th sec
            if let Ok(chunk) = input_producer.write_chunk_uninit(silence.len()) {
                chunk.fill_from_iter(silence.into_iter());
            }

            let start = Instant::now();
            while output_consumer.slots() == 0 {
                if start.elapsed() > Duration::from_secs(2) {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }

            running.store(false, Ordering::SeqCst);
            let _ = t.join().unwrap();

            assert!(output_consumer.slots() > 0);
        }));
    }

    for h in handles {
        h.join().unwrap();
    }
}

#[test]
fn test_encoder_multichannel_structure() {
    // Verify that we can feed 6-channel interleaved data without error.
    let buffer_size = 48000 * 6;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // Generate 1 seconds of "multichannel" data
    // Channel i gets value i/10.0
    // L=0.0, R=0.1, C=0.2, LFE=0.3, LS=0.4, RS=0.5
    let frames = 48000;
    let mut data = Vec::with_capacity(frames * 6);
    for _ in 0..frames {
        for ch in 0..6 {
            data.push(ch as f32 / 10.0);
        }
    }

    // Write data
    let mut written = 0;
    while written < data.len() {
        let remaining = data.len() - written;
        let request = remaining.min(1024 * 6); // Write in chunks
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(data[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    // Wait for processing
    thread::sleep(Duration::from_millis(500));

    // Stop
    running.store(false, Ordering::SeqCst);
    let _ = encoder_handle.join().unwrap();

    // Verify output exists
    let available_bytes = output_consumer.slots();
    println!("Encoded bytes from multichannel input: {}", available_bytes);
    assert!(
        available_bytes > 0,
        "Encoder failed to process multichannel input"
    );
}

#[test]
fn test_encoder_valid_iec61937() {
    // Validate that the output contains the IEC 61937 preamble
    // Preamble A: 0xF872 (LE: 0x72, 0xF8)
    // Preamble B: 0x4E1F (LE: 0x1F, 0x4E)
    // Sequence in bytes: [0x72, 0xF8, 0x1F, 0x4E]

    let buffer_size = 48000 * 6;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, mut output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // Feed 1 second of silence
    let samples = 48000 * 6;
    let silence = vec![0.0f32; samples];
    let mut written = 0;
    while written < samples {
        let request = (samples - written).min(1024);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    thread::sleep(Duration::from_millis(500));
    running.store(false, Ordering::SeqCst);
    let _ = encoder_handle.join().unwrap();

    // Analyze output
    let available = output_consumer.slots();
    let mut data = vec![0u8; available];
    if let Ok(chunk) = output_consumer.read_chunk(available) {
        for (i, byte) in chunk.into_iter().enumerate() {
            data[i] = byte;
        }
    }

    // Search for preamble
    let preamble = [0x72, 0xF8, 0x1F, 0x4E];
    let mut found = false;

    // Simple naive search
    if data.len() >= 4 {
        for i in 0..data.len() - 4 {
            if data[i..i + 4] == preamble {
                found = true;
                break;
            }
        }
    }

    assert!(found, "IEC 61937 preamble not found in encoder output!");
}

#[test]
fn test_encoder_restart() {
    // Verify that we can start, stop, and restart the encoder without issues.
    for i in 0..3 {
        println!("Iteration {}", i);
        let buffer_size = 48000 * 6;
        let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
        let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

        let running = Arc::new(AtomicBool::new(true));
        let encoder_running = running.clone();

        let encoder_handle = thread::spawn(move || {
            encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
        });

        // Feed some data - increased to 1s to ensure output
        let silence = vec![0.0f32; 48000];
        if let Ok(chunk) = input_producer.write_chunk_uninit(silence.len()) {
            chunk.fill_from_iter(silence.into_iter());
        }

        let start = Instant::now();
        while output_consumer.slots() == 0 {
            if start.elapsed() > Duration::from_secs(2) {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        running.store(false, Ordering::SeqCst);
        let result = encoder_handle.join();
        assert!(result.is_ok(), "Encoder failed to join on iteration {}", i);

        // Check we got something
        assert!(output_consumer.slots() > 0, "No output on iteration {}", i);
    }
}

#[test]
fn test_encoder_shutdown_under_output_backpressure() {
    // Tiny output buffer to force backpressure quickly while never draining it.
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(48_000 * 6);
    let (output_producer, _output_consumer) = RingBuffer::<u8>::new(128);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // Feed enough data to make ffmpeg produce multiple output reads.
    let silence = vec![0.0f32; 48_000 * 6];
    let mut written = 0;
    while written < silence.len() {
        let request = (silence.len() - written).min(1024 * 6);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    // Give the encoder a moment to hit the backpressure path.
    thread::sleep(Duration::from_millis(200));
    running.store(false, Ordering::SeqCst);

    // Join with timeout to catch hangs deterministically.
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(encoder_handle.join());
    });

    let join_result = rx
        .recv_timeout(Duration::from_secs(2))
        .expect("encoder did not terminate promptly under output backpressure");

    assert!(join_result.is_ok(), "encoder thread panicked");
    let loop_result = join_result.expect("panic already checked");
    assert!(
        loop_result.is_ok(),
        "encoder loop returned error: {loop_result:?}"
    );
}

#[test]
fn test_encoder_custom_config() {
    // Use minimal config values to exercise .max(1) clamping paths.
    let buffer_size = 48000 * 6;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let config = encoder::EncoderConfig {
        ffmpeg_thread_queue_size: 1,
        feeder_chunk_frames: 1,
    };

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop_with_config(
            input_consumer,
            output_producer,
            encoder_running,
            config,
        )
    });

    // Feed 0.5s of silence
    let samples = 48000 / 2 * 6;
    let silence = vec![0.0f32; samples];
    let mut written = 0;
    while written < samples {
        let request = (samples - written).min(256);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    thread::sleep(Duration::from_millis(500));
    running.store(false, Ordering::SeqCst);
    let result = encoder_handle.join();
    assert!(result.is_ok(), "encoder thread panicked with custom config");

    assert!(
        output_consumer.slots() > 0,
        "Encoder with custom config should produce output"
    );
}

#[test]
fn test_encoder_zero_config_values() {
    // Zero values should be clamped to 1 by .max(1), not panic.
    let buffer_size = 48000 * 6;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let config = encoder::EncoderConfig {
        ffmpeg_thread_queue_size: 0,
        feeder_chunk_frames: 0,
    };

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop_with_config(
            input_consumer,
            output_producer,
            encoder_running,
            config,
        )
    });

    let silence = vec![0.0f32; 48000];
    if let Ok(chunk) = input_producer.write_chunk_uninit(silence.len()) {
        chunk.fill_from_iter(silence);
    }

    let start = Instant::now();
    while output_consumer.slots() == 0 {
        if start.elapsed() > Duration::from_secs(2) {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    running.store(false, Ordering::SeqCst);
    let result = encoder_handle.join();
    assert!(result.is_ok(), "encoder thread panicked with zero config");
    assert!(
        output_consumer.slots() > 0,
        "Encoder with zero (clamped) config should produce output"
    );
}

#[test]
fn test_encoder_tiny_output_buffer() {
    // Very small output ring to exercise stdout_read_buffer_size clamping.
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(48000 * 6);
    let (output_producer, mut output_consumer) = RingBuffer::<u8>::new(64);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // Feed data and continuously drain the tiny output buffer.
    let silence = vec![0.0f32; 48000 * 6];
    let mut written = 0;
    while written < silence.len() {
        let request = (silence.len() - written).min(1024);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    // Drain output for a bit so the encoder doesn't stall on backpressure.
    let mut total_drained = 0usize;
    let drain_deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < drain_deadline {
        let available = output_consumer.slots();
        if available > 0 {
            if let Ok(chunk) = output_consumer.read_chunk(available) {
                total_drained += chunk.len();
                chunk.commit_all();
            }
        }
        thread::sleep(Duration::from_millis(5));
    }

    running.store(false, Ordering::SeqCst);
    let result = encoder_handle.join();
    assert!(result.is_ok(), "encoder panicked with tiny output buffer");
    assert!(
        total_drained > 0,
        "Should have drained some data from tiny output buffer"
    );
}

#[test]
fn test_encoder_output_frame_aligned() {
    // Verify output byte count is a multiple of OUTPUT_FRAME_BYTES_U8 (4).
    let buffer_size = 48000 * 6;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    let samples = 48000 * 6;
    let silence = vec![0.0f32; samples];
    let mut written = 0;
    while written < samples {
        let request = (samples - written).min(1024);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    thread::sleep(Duration::from_millis(500));
    running.store(false, Ordering::SeqCst);
    let _ = encoder_handle.join().unwrap();

    let available = output_consumer.slots();
    assert!(available > 0, "Should have output data");
    // IEC 61937 output should be frame-aligned to 4 bytes (2ch × S16LE).
    assert_eq!(
        available % 4,
        0,
        "Output byte count {} is not frame-aligned to 4 bytes",
        available
    );
}

#[test]
fn test_encoder_multiple_iec61937_frames() {
    // Feed 2 seconds of audio and count IEC 61937 preambles.
    // AC-3 at 48kHz produces ~31.25 frames/sec → expect ≥10 in 2s.
    let buffer_size = 48000 * 6 * 3; // big enough for 2s+
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, mut output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    // Feed 2 seconds of silence
    let total_samples = 48000 * 2 * 6;
    let silence = vec![0.0f32; total_samples];
    let mut written = 0;
    while written < total_samples {
        let request = (total_samples - written).min(1024);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    thread::sleep(Duration::from_millis(1500));
    running.store(false, Ordering::SeqCst);
    let _ = encoder_handle.join().unwrap();

    // Drain all output
    let available = output_consumer.slots();
    let mut data = vec![0u8; available];
    if let Ok(chunk) = output_consumer.read_chunk(available) {
        for (i, byte) in chunk.into_iter().enumerate() {
            data[i] = byte;
        }
    }

    // Count IEC 61937 preambles: [0x72, 0xF8, 0x1F, 0x4E]
    let preamble = [0x72u8, 0xF8, 0x1F, 0x4E];
    let mut count = 0;
    if data.len() >= 4 {
        for i in 0..data.len() - 3 {
            if data[i..i + 4] == preamble {
                count += 1;
            }
        }
    }

    println!(
        "Found {} IEC 61937 preambles in {} bytes",
        count,
        data.len()
    );
    assert!(
        count >= 10,
        "Expected ≥10 IEC 61937 frames for 2s of audio, found {}",
        count
    );
}

#[test]
fn test_encoder_iec61937_frame_spacing() {
    // Verify IEC 61937 frames are at 6144-byte intervals (AC-3 standard).
    let buffer_size = 48000 * 6 * 3;
    let (mut input_producer, input_consumer) = RingBuffer::<f32>::new(buffer_size);
    let (output_producer, mut output_consumer) = RingBuffer::<u8>::new(buffer_size * 4);

    let running = Arc::new(AtomicBool::new(true));
    let encoder_running = running.clone();

    let encoder_handle = thread::spawn(move || {
        encoder::run_encoder_loop(input_consumer, output_producer, encoder_running)
    });

    let total_samples = 48000 * 2 * 6;
    let silence = vec![0.0f32; total_samples];
    let mut written = 0;
    while written < total_samples {
        let request = (total_samples - written).min(1024);
        if let Ok(chunk) = input_producer.write_chunk_uninit(request) {
            let n = chunk.len();
            chunk.fill_from_iter(silence[written..written + n].iter().copied());
            written += n;
        } else {
            thread::sleep(Duration::from_millis(1));
        }
    }

    thread::sleep(Duration::from_millis(1500));
    running.store(false, Ordering::SeqCst);
    let _ = encoder_handle.join().unwrap();

    let available = output_consumer.slots();
    let mut data = vec![0u8; available];
    if let Ok(chunk) = output_consumer.read_chunk(available) {
        for (i, byte) in chunk.into_iter().enumerate() {
            data[i] = byte;
        }
    }

    // Find all preamble positions
    let preamble = [0x72u8, 0xF8, 0x1F, 0x4E];
    let mut positions = Vec::new();
    if data.len() >= 4 {
        for i in 0..data.len() - 3 {
            if data[i..i + 4] == preamble {
                positions.push(i);
            }
        }
    }

    assert!(
        positions.len() >= 3,
        "Need at least 3 preambles to check spacing, found {}",
        positions.len()
    );

    // Check spacing between consecutive preambles.
    // AC-3 IEC 61937: each burst = 6144 bytes (1536 frames × 2 channels × 2 bytes/sample).
    for window in positions.windows(2) {
        let spacing = window[1] - window[0];
        assert_eq!(
            spacing, 6144,
            "IEC 61937 frame spacing should be 6144 bytes, got {} (at positions {} and {})",
            spacing, window[0], window[1]
        );
    }
}

#[test]
fn test_encoder_config_default_values() {
    let config = encoder::EncoderConfig::default();
    assert_eq!(config.ffmpeg_thread_queue_size, 128);
    assert_eq!(config.feeder_chunk_frames, 128);
}

#[test]
fn test_pipewire_config_default_values() {
    use pw_ac3_live::pipewire_client::PipewireConfig;
    let config = PipewireConfig::default();
    assert_eq!(config.node_latency, "64/48000");
}
