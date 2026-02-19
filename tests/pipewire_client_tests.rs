mod pipewire_client_impl {
    #![allow(dead_code)]

    include!("../src/pipewire_client.rs");

    mod moved_tests {
        use super::*;
        use rtrb::RingBuffer;
        use std::mem::size_of;
        use std::sync::atomic::AtomicBool;

        fn parse_f32_plane(raw_data: &[u8], offset: usize, size: usize) -> Option<Vec<f32>> {
            let mut samples = Vec::new();
            parse_f32_plane_into(raw_data, offset, size, &mut samples)?;
            Some(samples)
        }

        fn parse_f32_interleaved(
            raw_data: &[u8],
            offset: usize,
            size: usize,
            channels: usize,
        ) -> Option<Vec<f32>> {
            let mut samples = Vec::new();
            parse_f32_interleaved_into(raw_data, offset, size, channels, &mut samples)?;
            Some(samples)
        }

        fn parse_interleaved_from_stride(
            raw_data: &[u8],
            offset: usize,
            size: usize,
            stride: usize,
        ) -> Option<Vec<f32>> {
            let mut samples = Vec::new();
            parse_interleaved_from_stride_into(raw_data, offset, size, stride, &mut samples)?;
            Some(samples)
        }

        #[test]
        fn parse_f32_plane_accepts_valid_aligned_chunk() {
            let data = [0.5f32, -1.25f32, 3.0f32];
            let mut bytes = Vec::with_capacity(data.len() * size_of::<f32>());
            for sample in data {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }

            let parsed =
                parse_f32_plane(&bytes, 0, bytes.len()).expect("aligned chunk should parse");
            assert_eq!(parsed, vec![0.5, -1.25, 3.0]);
        }

        #[test]
        fn parse_f32_plane_rejects_unaligned_offset() {
            let mut bytes = vec![0u8];
            bytes.extend_from_slice(&1.0f32.to_le_bytes());

            assert!(parse_f32_plane(&bytes, 1, size_of::<f32>()).is_none());
        }

        #[test]
        fn parse_f32_plane_rejects_non_multiple_of_f32_size() {
            let bytes = vec![0u8; size_of::<f32>() + 1];
            assert!(parse_f32_plane(&bytes, 0, bytes.len()).is_none());
        }

        #[test]
        fn parse_f32_plane_rejects_out_of_bounds_range() {
            let bytes = vec![0u8; 8];
            assert!(parse_f32_plane(&bytes, 4, 8).is_none());
        }

        #[test]
        fn parse_f32_interleaved_truncates_partial_frame() {
            let samples = [1.0f32, 2.0, 3.0, 4.0, 5.0];
            let mut bytes = Vec::with_capacity(samples.len() * size_of::<f32>());
            for sample in samples {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }

            let parsed = parse_f32_interleaved(&bytes, 0, bytes.len(), 2)
                .expect("interleaved chunk should parse");
            assert_eq!(parsed, vec![1.0, 2.0, 3.0, 4.0]);
        }

        #[test]
        fn parse_f32_interleaved_rejects_zero_channels() {
            let bytes = vec![0u8; 8];
            assert!(parse_f32_interleaved(&bytes, 0, bytes.len(), 0).is_none());
        }

        #[test]
        fn parse_interleaved_from_stride_reads_f32_stereo_and_pads_to_51() {
            let mut bytes = Vec::new();
            for sample in [1.0f32, -1.0f32, 0.25f32, -0.25f32] {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }

            let parsed =
                parse_interleaved_from_stride(&bytes, 0, bytes.len(), 8).expect("should parse");
            assert_eq!(parsed.len(), 12);
            assert_eq!(parsed[0], 1.0);
            assert_eq!(parsed[1], -1.0);
            assert_eq!(parsed[2], 0.0);
            assert_eq!(parsed[6], 0.25);
            assert_eq!(parsed[7], -0.25);
        }

        #[test]
        fn parse_interleaved_from_stride_reads_s16_stereo_and_pads_to_51() {
            let mut bytes = Vec::new();
            for sample in [i16::MAX, i16::MIN, 1000i16, -1000i16] {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }

            let parsed =
                parse_interleaved_from_stride(&bytes, 0, bytes.len(), 4).expect("should parse");
            assert_eq!(parsed.len(), 12);
            assert!(parsed[0].is_finite());
            assert!(parsed[1].is_finite());
            assert_eq!(parsed[2], 0.0);
            assert!(parsed[6].is_finite());
            assert!(parsed[7].is_finite());
        }

        #[test]
        fn playback_target_numeric_string_sets_connect_id_and_property() {
            let target = resolve_playback_target(Some("42"));
            assert_eq!(target.connect_target_id, Some(42));
            assert_eq!(target.target_object.as_deref(), Some("42"));

            let props = build_playback_properties(&target);
            assert_eq!(props.get("target.object"), Some("42"));
            assert_eq!(props.get("node.autoconnect"), Some("false"));
        }

        #[test]
        fn playback_target_name_sets_only_target_object_property() {
            let target = resolve_playback_target(Some("alsa_output.pci-0000_00_1f.3.hdmi-stereo"));
            assert_eq!(target.connect_target_id, None);
            assert_eq!(
                target.target_object.as_deref(),
                Some("alsa_output.pci-0000_00_1f.3.hdmi-stereo")
            );

            let props = build_playback_properties(&target);
            assert_eq!(
                props.get("target.object"),
                Some("alsa_output.pci-0000_00_1f.3.hdmi-stereo")
            );
            assert_eq!(props.get("node.autoconnect"), Some("false"));
        }

        #[test]
        fn playback_target_blank_string_is_ignored() {
            let target = resolve_playback_target(Some("   "));
            assert_eq!(target.connect_target_id, None);
            assert_eq!(target.target_object, None);

            let props = build_playback_properties(&target);
            assert_eq!(props.get("target.object"), None);
            assert_eq!(props.get("node.autoconnect"), Some("true"));
        }

        #[test]
        fn stdout_output_loop_flushes_buffer_and_exits_after_stop() {
            let (mut producer, mut consumer) = RingBuffer::<u8>::new(32);
            let expected = [1u8, 2, 3, 4, 5, 6];
            {
                let chunk = producer
                    .write_chunk_uninit(expected.len())
                    .expect("producer should have space");
                chunk.fill_from_iter(expected.iter().copied());
            }

            let running = Arc::new(AtomicBool::new(true));
            let running_for_thread = running.clone();
            let handle = thread::spawn(move || {
                let mut written = Vec::<u8>::new();
                run_stdout_output_loop(&mut consumer, running_for_thread.as_ref(), &mut written)
                    .expect("stdout loop should exit cleanly");
                written
            });

            running.store(false, Ordering::SeqCst);
            let written = handle.join().expect("stdout loop thread should not panic");
            assert_eq!(written, expected);
        }

        // ── parse_interleaved_from_stride edge cases ──────────────────

        #[test]
        fn stride_6ch_f32_no_padding() {
            // 6-channel f32: stride = 6 * 4 = 24 bytes per frame.
            // Two frames of ascending values.
            let mut bytes = Vec::new();
            for frame in 0..2u32 {
                for ch in 0..6u32 {
                    let val = (frame * 6 + ch) as f32;
                    bytes.extend_from_slice(&val.to_le_bytes());
                }
            }
            let parsed = parse_interleaved_from_stride(&bytes, 0, bytes.len(), 24)
                .expect("6ch f32 should parse");
            // 2 frames × 6 channels = 12 samples, no zero-padding needed.
            assert_eq!(parsed.len(), 12);
            assert_eq!(parsed[0], 0.0); // frame0 ch0
            assert_eq!(parsed[5], 5.0); // frame0 ch5
            assert_eq!(parsed[6], 6.0); // frame1 ch0
            assert_eq!(parsed[11], 11.0); // frame1 ch5
        }

        #[test]
        fn stride_mono_f32_pads_to_6ch() {
            // Mono f32: stride = 4 bytes. Two frames.
            let mut bytes = Vec::new();
            for val in [0.5f32, -0.5f32] {
                bytes.extend_from_slice(&val.to_le_bytes());
            }
            let parsed = parse_interleaved_from_stride(&bytes, 0, bytes.len(), 4)
                .expect("mono f32 should parse");
            // 2 frames × 6 channels = 12 samples
            assert_eq!(parsed.len(), 12);
            assert_eq!(parsed[0], 0.5); // frame0 ch0
            assert_eq!(parsed[1], 0.0); // frame0 ch1 (padded)
            assert_eq!(parsed[5], 0.0); // frame0 ch5 (padded)
            assert_eq!(parsed[6], -0.5); // frame1 ch0
            assert_eq!(parsed[7], 0.0); // frame1 ch1 (padded)
        }

        #[test]
        fn stride_6ch_s16() {
            // 6-channel s16: stride = 6 * 2 = 12 bytes per frame.
            let mut bytes = Vec::new();
            for val in [i16::MAX, 0i16, i16::MIN, 1000i16, -1000i16, 500i16] {
                bytes.extend_from_slice(&val.to_le_bytes());
            }
            let parsed = parse_interleaved_from_stride(&bytes, 0, bytes.len(), 12)
                .expect("6ch s16 should parse");
            assert_eq!(parsed.len(), 6);
            // All values should be finite floats in [-1.0, 1.0)
            for sample in &parsed {
                assert!(sample.is_finite());
                assert!(*sample >= -1.0 && *sample <= 1.0);
            }
        }

        #[test]
        fn stride_mono_s16_pads_to_6ch() {
            // Mono s16: stride = 2 bytes. Two frames.
            let mut bytes = Vec::new();
            for val in [16000i16, -16000i16] {
                bytes.extend_from_slice(&val.to_le_bytes());
            }
            let parsed = parse_interleaved_from_stride(&bytes, 0, bytes.len(), 2)
                .expect("mono s16 should parse");
            assert_eq!(parsed.len(), 12);
            assert!(parsed[0].is_finite() && parsed[0] > 0.0);
            assert_eq!(parsed[1], 0.0); // padded
            assert_eq!(parsed[5], 0.0); // padded
            assert!(parsed[6].is_finite() && parsed[6] < 0.0);
            assert_eq!(parsed[7], 0.0); // padded
        }

        #[test]
        fn stride_invalid_size_returns_none() {
            // Stride of 3 is not a multiple of sizeof(f32) or sizeof(i16).
            let bytes = vec![0u8; 12];
            assert!(parse_interleaved_from_stride(&bytes, 0, bytes.len(), 3).is_none());
        }

        #[test]
        fn stride_zero_returns_none() {
            let bytes = vec![0u8; 8];
            assert!(parse_interleaved_from_stride(&bytes, 0, bytes.len(), 0).is_none());
        }

        #[test]
        fn stride_too_few_bytes_returns_none() {
            // Data shorter than one stride.
            let bytes = vec![0u8; 3];
            assert!(parse_interleaved_from_stride(&bytes, 0, bytes.len(), 8).is_none());
        }

        #[test]
        fn stride_7ch_f32_exceeds_max_returns_none() {
            // 7-channel f32: stride = 28 bytes. Exceeds INPUT_CHANNELS (6).
            let bytes = vec![0u8; 56]; // 2 frames
            assert!(parse_interleaved_from_stride(&bytes, 0, bytes.len(), 28).is_none());
        }

        // ── resolve_playback_target ───────────────────────────────────

        #[test]
        fn playback_target_none_enables_autoconnect() {
            let target = resolve_playback_target(None);
            assert_eq!(target.connect_target_id, None);
            assert_eq!(target.target_object, None);

            let props = build_playback_properties(&target);
            assert_eq!(props.get("target.object"), None);
            assert_eq!(props.get("node.autoconnect"), Some("true"));
        }

        // ── run_stdout_output_loop edge cases ─────────────────────────

        #[test]
        fn stdout_output_loop_empty_buffer_exits_cleanly() {
            let (_producer, mut consumer) = RingBuffer::<u8>::new(32);
            let running = AtomicBool::new(false); // already stopped
            let mut written = Vec::<u8>::new();
            run_stdout_output_loop(&mut consumer, &running, &mut written)
                .expect("should exit cleanly");
            assert!(written.is_empty());
        }

        #[test]
        fn stdout_output_loop_propagates_write_error() {
            use std::io;

            struct FailWriter;
            impl Write for FailWriter {
                fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
                    Err(io::Error::new(io::ErrorKind::BrokenPipe, "mock error"))
                }
                fn flush(&mut self) -> io::Result<()> {
                    Ok(())
                }
            }

            let (mut producer, mut consumer) = RingBuffer::<u8>::new(32);
            {
                let chunk = producer.write_chunk_uninit(4).expect("should have space");
                chunk.fill_from_iter([1u8, 2, 3, 4].iter().copied());
            }

            let running = AtomicBool::new(true);
            let mut writer = FailWriter;
            let result = run_stdout_output_loop(&mut consumer, &running, &mut writer);
            assert!(result.is_err());
        }

        // ── parse_f32_plane offset handling ───────────────────────────

        #[test]
        fn parse_f32_plane_with_nonzero_offset() {
            // Place 2 padding bytes then 2 f32 samples at offset 8 (aligned).
            let mut bytes = vec![0u8; 8]; // 8 bytes of padding
            bytes.extend_from_slice(&1.5f32.to_le_bytes());
            bytes.extend_from_slice(&(-2.5f32).to_le_bytes());

            let parsed = parse_f32_plane(&bytes, 8, 8).expect("offset 8 should parse");
            assert_eq!(parsed, vec![1.5, -2.5]);
        }

        // ── parse_f32_interleaved happy path ──────────────────────────

        #[test]
        fn parse_f32_interleaved_exact_frame_count() {
            // 6 samples = exactly 2 frames of 3 channels. No truncation needed.
            let samples = [1.0f32, 2.0, 3.0, 4.0, 5.0, 6.0];
            let mut bytes = Vec::with_capacity(samples.len() * size_of::<f32>());
            for sample in samples {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }

            let parsed = parse_f32_interleaved(&bytes, 0, bytes.len(), 3)
                .expect("exact frame count should parse");
            assert_eq!(parsed, vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);
        }

        // ── parse_interleaved_from_stride with offset ─────────────────

        #[test]
        fn stride_nonzero_offset() {
            // 8 bytes of padding, then 2 stereo f32 frames at offset 8.
            let mut bytes = vec![0u8; 8]; // padding
            for val in [0.25f32, -0.25f32, 0.75f32, -0.75f32] {
                bytes.extend_from_slice(&val.to_le_bytes());
            }

            let parsed =
                parse_interleaved_from_stride(&bytes, 8, 16, 8).expect("offset 8 should parse");
            assert_eq!(parsed.len(), 12); // 2 frames × 6 channels
            assert_eq!(parsed[0], 0.25);
            assert_eq!(parsed[1], -0.25);
            assert_eq!(parsed[2], 0.0); // padded
            assert_eq!(parsed[6], 0.75);
        }

        #[test]
        fn stride_offset_overflow_returns_none() {
            let bytes = vec![0u8; 16];
            // offset + size overflows usize via checked_add.
            assert!(parse_interleaved_from_stride(&bytes, usize::MAX, 1, 4).is_none());
        }
    }
}
