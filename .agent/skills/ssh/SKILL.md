---
name: ssh
description: Guidelines for executing scripts and commands remotely via SSH.
---

# SSH Skill

This skill provides standardized commands for executing scripts and commands remotely via SSH.


## Usage

### 1. Execute a Single Command
To run a command and see its output:
```bash
ssh steamdeck "command_to_run"
```

### 2. Execute a local script
This allows to run a script that is not available on the deck.
```bash
ssh steamdeck 'bash -s' < "local/path/to/script.sh"
```

### 3. Execute a short remote script
The target script must be available on the deck.
(The `pw_operator` skill could be used to deploy the script on the deck in the folder /home/deck/Downloads/pw-ac3-live-steamdeck-0.1.0).

```bash
ssh steamdeck "/remote/path/to/script.sh"
```

### 4. Execute a long-running remote script
The target script must be available on the deck.
(The `pw_operator` skill could be used to deploy the script on the deck in the folder /home/deck/Downloads/pw-ac3-live-steamdeck-0.1.0).

**CRITICAL**: Use `-t` to allocate a pseudo-terminal. This is required for long-running processes that need to handle signals (Ctrl+C).

```bash
ssh -t steamdeck "/remote/path/to/script.sh"
```
