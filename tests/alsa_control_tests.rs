mod alsa_control_impl {
    #![allow(dead_code)]

    include!("../src/alsa_control.rs");

    mod moved_tests {
        use super::DirectAlsaHardwareGuard;

        fn guard(card: &str, index: &str) -> DirectAlsaHardwareGuard {
            DirectAlsaHardwareGuard {
                iec_card: card.to_string(),
                iec_index: index.to_string(),
            }
        }

        #[test]
        fn iecset_args_use_selected_card_and_index() {
            let guard = guard("7", "3");
            let args = guard.iecset_args(&["audio", "off", "rate", "48000"]);
            assert_eq!(
                args,
                vec!["-c", "7", "-n", "3", "audio", "off", "rate", "48000",]
                    .into_iter()
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            );
        }

        #[test]
        fn amixer_control_args_use_selected_card() {
            let guard = guard("5", "2");
            assert_eq!(guard.amixer_master_args()[1], "5");
            assert_eq!(guard.amixer_pcm_args()[1], "5");
            assert_eq!(guard.amixer_iec_args()[1], "5");
        }

        #[test]
        fn amixer_iec_control_uses_selected_index() {
            let guard = guard("0", "9");
            assert_eq!(guard.amixer_iec_args()[3], "IEC958,9");
        }

        #[test]
        fn startup_commands_follow_expected_order_and_payloads() {
            let guard = guard("0", "2");
            let commands = guard.startup_commands();

            assert_eq!(commands.len(), 4);
            assert_eq!(commands[0].program, "iecset");
            assert_eq!(
                commands[0].args,
                vec!["-c", "0", "-n", "2", "audio", "off", "rate", "48000"]
                    .into_iter()
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            );
            assert_eq!(commands[1].program, "amixer");
            assert_eq!(commands[1].args[3], "Master");
            assert_eq!(commands[2].program, "amixer");
            assert_eq!(commands[2].args[3], "PCM");
            assert_eq!(commands[3].program, "amixer");
            assert_eq!(commands[3].args[3], "IEC958,2");
        }

        #[test]
        fn shutdown_commands_restore_pcm_audio_mode() {
            let guard = guard("4", "8");
            let commands = guard.shutdown_commands();

            assert_eq!(commands.len(), 1);
            assert_eq!(commands[0].program, "iecset");
            assert_eq!(
                commands[0].args,
                vec!["-c", "4", "-n", "8", "audio", "on"]
                    .into_iter()
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            );
        }
    }
}
