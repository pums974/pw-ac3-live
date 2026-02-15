mod pipewire_client_impl {
    #![allow(dead_code)]

    include!("../src/pipewire_client.rs");

    mod moved_tests {
        use super::*;
        use rtrb::RingBuffer;
        use std::mem::size_of;
        use std::sync::atomic::AtomicBool;

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
        }

        #[test]
        fn playback_target_blank_string_is_ignored() {
            let target = resolve_playback_target(Some("   "));
            assert_eq!(target.connect_target_id, None);
            assert_eq!(target.target_object, None);

            let props = build_playback_properties(&target);
            assert_eq!(props.get("target.object"), None);
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
    }
}
