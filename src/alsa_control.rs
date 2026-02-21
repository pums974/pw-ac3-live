use log::{info, warn};

#[cfg(target_os = "linux")]
use std::process::Command;

/// Best-effort ALSA hardware setup/restore used by `--alsa-direct` mode.
///
/// This guard is intentionally non-fatal: on machines without matching controls,
/// startup continues and warnings are logged, mirroring the previous shell script behavior.
#[derive(Debug, Clone)]
pub struct DirectAlsaHardwareGuard {
    iec_card: String,
    iec_index: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommandSpec {
    program: &'static str,
    args: Vec<String>,
    context: &'static str,
}

impl DirectAlsaHardwareGuard {
    /// Configures IEC958/mixer state for direct ALSA mode.
    ///
    /// Typical Steam Deck values are `iec_card=0` and `iec_index=2`.
    pub fn setup(iec_card: String, iec_index: String) -> Self {
        let guard = Self {
            iec_card,
            iec_index,
        };

        guard.apply_commands(guard.startup_commands());
        guard
    }

    fn apply_commands(&self, commands: Vec<CommandSpec>) {
        for command in commands {
            run_command_best_effort(command.program, &command.args, command.context);
        }
    }

    fn startup_commands(&self) -> Vec<CommandSpec> {
        vec![
            CommandSpec {
                program: "iecset",
                args: self.iecset_args(&["audio", "off", "rate", "48000"]),
                context: "Set IEC958 to non-audio mode",
            },
            CommandSpec {
                program: "amixer",
                args: self.amixer_master_args(),
                context: "Set ALSA Master to 100% and unmute",
            },
            CommandSpec {
                program: "amixer",
                args: self.amixer_pcm_args(),
                context: "Set ALSA PCM to 100% and unmute",
            },
            CommandSpec {
                program: "amixer",
                args: self.amixer_iec_args(),
                context: "Unmute IEC958 control",
            },
        ]
    }

    fn shutdown_commands(&self) -> Vec<CommandSpec> {
        vec![CommandSpec {
            program: "iecset",
            args: self.iecset_args(&["audio", "on"]),
            context: "Restore IEC958 to PCM audio mode",
        }]
    }

    fn iecset_args(&self, tail: &[&str]) -> Vec<String> {
        let mut args = vec![
            "-c".to_string(),
            self.iec_card.clone(),
            "-n".to_string(),
            self.iec_index.clone(),
        ];
        args.extend(tail.iter().map(|arg| (*arg).to_string()));
        args
    }

    fn amixer_master_args(&self) -> Vec<String> {
        vec![
            "-c".to_string(),
            self.iec_card.clone(),
            "set".to_string(),
            "Master".to_string(),
            "unmute".to_string(),
            "100%".to_string(),
        ]
    }

    fn amixer_pcm_args(&self) -> Vec<String> {
        vec![
            "-c".to_string(),
            self.iec_card.clone(),
            "set".to_string(),
            "PCM".to_string(),
            "unmute".to_string(),
            "100%".to_string(),
        ]
    }

    fn amixer_iec_args(&self) -> Vec<String> {
        vec![
            "-c".to_string(),
            self.iec_card.clone(),
            "set".to_string(),
            format!("IEC958,{}", self.iec_index),
            "unmute".to_string(),
        ]
    }
}

impl Drop for DirectAlsaHardwareGuard {
    fn drop(&mut self) {
        self.apply_commands(self.shutdown_commands());
    }
}

#[cfg(target_os = "linux")]
fn run_command_best_effort(program: &str, args: &[String], context: &str) {
    match Command::new(program).args(args).output() {
        Ok(output) if output.status.success() => {
            info!("{context}: ok");
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            if stderr.is_empty() {
                warn!(
                    "{context}: command failed (status: {:?})",
                    output.status.code()
                );
            } else {
                warn!(
                    "{context}: command failed (status: {:?}): {}",
                    output.status.code(),
                    stderr
                );
            }
        }
        Err(err) => {
            warn!("{context}: failed to spawn '{program}': {err}");
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn run_command_best_effort(program: &str, _args: &[String], context: &str) {
    warn!("{context}: '{program}' not executed (unsupported platform)");
}
