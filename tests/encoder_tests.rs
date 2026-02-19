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

    // Generate 0.5 seconds of "multichannel" data
    // Channel i gets value i/10.0
    // L=0.0, R=0.1, C=0.2, LFE=0.3, LS=0.4, RS=0.5
    let frames = 48000 / 2;
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
            if &data[i..i + 4] == &preamble {
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
