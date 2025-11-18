# ssh_run.sh

## 1. Summary
`ssh_run.sh` is a high-reliability parallel execution framework designed for environments where dozens or hundreds of systems must be validated or updated at once. It performs automated reachability checks, SSH and privilege verification, and can distribute and execute a payload script across all accessible hosts in a controlled, auditable way. It replaces manual SSH loops, ad-hoc scripting, and inconsistent operator workflows with a unified, safe, and repeatable process suitable for large-scale enterprise operations.


## 2. How It Works
1. You run the script with:
   ```
   ./ssh_run.sh inventory_file [payload_file]
   ```
2. The script performs several early sanity checks (required binaries, permissions, environment validation). If any check fails, the user is informed with a clear error message and execution stops.
3. If the inventory file is not provided, the script immediately displays usage instructions and exits.
4. If not already inside a `screen` session, the script restarts itself in one to ensure stable output and uninterrupted logging.
5. The inventory file is validated, cleaned, normalized, and copied to a dedicated temporary file.  
   This prevents conflicts or corruption when multiple concurrent runs use the same inventory.
6. A PING test is executed in parallel, resolving via `/etc/hosts` first, then DNS fallbacks.
7. SSH and sudo access checks run in parallel across all reachable hosts.
8. If a payload is provided, it is streamed to each target and executed under that system’s **default shell**, since the script does not enforce a remote interpreter.
9. All logs and host-specific outputs are written into an isolated run directory:
   ```
   log_ssh_run/YYMMDD_PID_<INVENTORY|PAYLOAD_NAME>
   ```
10. A FAILED host list is created when connection, access, or payload execution issues occur.

---

## 3. Customization Required Before Use

`ssh_run.sh` is environment-agnostic by design.  
To use it correctly in your infrastructure, you must customize several parts of the script.

---

#### 1. Jumphost Detection (function: `set_variables()`)
The script detects the jumphost using hostname patterns:

```bash
case "$LOCAL_JH" in
    lab*|mgmt*)
        USER_TO_RUN_AS="opsuser"
        TARGET_SSH_USER="root"
        ;;
    prod*)
        USER_TO_RUN_AS="root"
        TARGET_SSH_USER="root"
        ;;
    *)
        USER_TO_RUN_AS="UNKNOWN"
        TARGET_SSH_USER="UNKNOWN"
        ;;
esac
```

Modify these patterns and user mappings to match your own environment.

---

#### 2. Skip List (function: `set_variables()`)
If certain hosts must always be skipped, adjust:

```bash
SKIP_HOSTS=(
	"testnode01"
	"legacy-backup02"
)
```

You may remove items or leave the list empty.

---
#### 3. VIOS/LPAR Detection (function: `is_vios()`)
The script adjusts its behavior when running against VIOS systems, because VIOS has different privilege-escalation rules compared to standard AIX LPARs.

```bash
is_vios() {
    local host="${1,,}"
    [[ "$host" =~ ^vios[0-9]+$ ]]
}
```
Command used:
`CLIENT_SUDO_COMMAND="/usr/ios/cli/ioscli oem_setup_env"`

---

#### 4. DNS Domain Resolution Rules  
**Function:** `ping_test()`

During PING testing, the script builds a list of domain suffixes based on hostname patterns:

```bash
case "${SYSTEM}" in
    app*|srv*)
        FQDN_LIST=(".example.net" ".corp.example.net")
        ;;
    db*|vios*)
        FQDN_LIST=(".example.net" ".mgmt.example.net")
        ;;
    *)
        FQDN_LIST=(".example.net")
        ;;
esac
```

Update the suffixes so they match your actual DNS structure (for example `.mycompany.net`, `.dc.local`, etc.).

---

#### 5. Hostname Cleanup (function: `display_ping_sudo_results()`)
The FAILED hosts file removes a fixed domain suffix:

```bash
HOST_CLEANUP_NW_CMD='s/(\\.example\\.net)//'
```

Adjust this rule if you use a different domain, or remove the rule entirely if you want full FQDNs.

---

#### 6. Payload Log Filename Cleanup (function: `check_empty_log_file()`)
During detection of empty or invalid per-host payload logs, the script extracts hostnames from log filenames. 
Update the cleanup command so it correctly strips only the file extension used by your logging structure:

```bash
HOST_CLEANUP_PAYLOAD_FILE_CMD_SED=(sed 's/\(\.txt\|\.err\)//')
```

---

## Summary

Before running the script, ensure you customize:

- jumphost detection rules  
- skip list  
- DNS suffix logic (`ping_test()`)  
- VIOS detection pattern (`is_vios()`)  
- hostname cleanup rule (`display_ping_sudo_results()`)  

Once customized, `ssh_run.sh` becomes portable and ready for any Linux/AIX automation setup.

---

## 4. Features
- Parallel execution across all hosts  
- Concurrency limiter to avoid overload  
- Fully safe concurrent mode (multiple script runs can operate at the same time)  
- Automatic `screen` session handling  
- Strict validation for inventory and payload files  
- Mixed-environment support (Linux, AIX, VIOS)  
- Host-type–aware access handling  
- Atomic per-host logging (no interleaving)  
- Dedicated run folder for each execution  
- FAILED host retry workflow  
- Inventory cleanup and normalization  
- Optional payload execution  
- Payload interpreter is whatever the target system uses by default  
- Automatic cleanup on exit or interruption (INT/TERM), preventing stale temporary files or partial logs
- VIOS-aware sudo handling: the script detects VIOS targets and automatically adjusts the sudo command to match their privilege model

---

## 5. Example Output

Below is a sample truncated output from a real run.
This demonstrates the structure of the PING phase, SSH/SUDO validation,
parallel execution, and the final summary.

> Note: This is only an example. Actual output will vary based on environment,
> inventory contents, and host availability.

```
################################################## Starting script ##################################################

JUMP HOST OS TYPE: AIX

======================================================================================================================
PING test on 4 host(s)
======================================================================================================================

host1                              WARN    RC: not in hosts, switching to DNS
host2                              WARN    RC: not in hosts, switching to DNS
host_skip1                         SKIP    Host intentionally excluded
host3                              WARN    RC: not in hosts, switching to DNS
host3.example.net                  WARN    RC: 1 (unreachable)
host1.example.net                  PASS
host2.example.net                  PASS
host3-alt.example.net              WARN    RC: 1 (unreachable)
host3-backup.example.net           WARN    RC: 1 (unreachable)
host3-backup.example.net           FAIL    RC: 1 (unreachable)

PING test completed -> | HOSTS: 4 | PASS: 2 | FAIL: 1 |
======================================================================================================================





======================================================================================================================
SUDO test on 2 host(s)
======================================================================================================================

host2.example.net                  FAIL    RC: 255
host1.example.net                  PASS

SUDO test completed -> | HOSTS: 2 | PASS: 1 | FAIL: 1 |
======================================================================================================================





======================================================================================================================
Running payload_template on 1 host(s)
======================================================================================================================

----------------------------------------------------------------------------------------------------------------------
Executing payload on host1.example.net

# uname
AIX

# echo "I am $(whoami) from $(hostname)"
I am root from host1

PASS: Payload executed successfully on host1.example.net
----------------------------------------------------------------------------------------------------------------------

======================================================================================================================





======================================================================================================================
PING/SUDO SUMMARY
======================================================================================================================

----------------------------------------------------------------------------------------------------------------------
PING failed on 1 host(s):

- host3-backup.example.net
----------------------------------------------------------------------------------------------------------------------


----------------------------------------------------------------------------------------------------------------------
SUDO failed on 1 host(s):

- host2.example.net
----------------------------------------------------------------------------------------------------------------------


--------------------| SUMMARY |--------------------

TOTAL HOSTS:        4
PING FAIL:          1
SUDO FAIL:          1
TOTAL FAIL:         2
ACCESSIBLE:         1
EST RUN TIME:       11s

--------------------| SUMMARY |--------------------

Main log directory: "log_ssh_run/251117_xxxxxx_payload_template"
Failed hosts present: "log_ssh_run/251117_xxxxxx_payload_template/payload_template_FAILED.txt" created

################################################## Script finalized ##################################################
```

---

## 6. Requirements

### OS & Shell
- Bash 4+
- Linux or AIX jumphost
- The script enforces Bash on the jumphost using an internal ensure_bash() mechanism.  
If a compatible Bash interpreter cannot be found, the script stops immediately.

### Required Binaries
- perl, tee, id, screen, mktemp, awk  
- Linux: `usleep`  
- AIX: GNU tools expected in `/opt/freeware/bin`

The script automatically **checks for all required binaries at startup**.  
If any required command is missing, the script stops immediately with a clear error message.

### Permissions
- SSH key-based authentication to all targets  
- Target user must be able to run:
  ```
  sudo su -
  ```
  without password  
- Script must run from an approved jumphost (auto-detected)

### File Naming Rules
- Inventory must start with `inventory_`
- Payload must start with `payload_`

### Environment Constraints
- Must run from a recognized jumphost
- Logs stored under:
  ```
  log_ssh_run/
  ```

---

## 7. Payload Template

`payload_template` is optional and serves as a reference for building structured payloads.  
It is streamed directly to each target and executed as root via:

```bash
cat payload_file | ssh target "sudo su -"
```

The remote interpreter is **the target system’s default shell**, unless the payload explicitly enforces Bash.

---

#### Structure and Options

The template includes several optional components:

#### 1. Interpreter Enforcement (`ensure_bash`)
Use this only if your payload requires Bash-specific features (arrays, `[[ ]]`, extended expansions).  
If the payload is POSIX-compatible, you may remove this function entirely.

#### 2. Manual-Run Style Output (`run_manual_commands`)
Prints commands in a way that resembles an operator typing them manually.  
Useful for clean auditing and readable logs on large runs.

---

#### Using the Template

If you do not need the optional helpers, write your commands directly after:

```bash
set -euo pipefail
```

They will execute as-is under `sudo su -` on the target.

Payload files **do not need execution permission** for remote execution, because they are streamed via SSH rather than run locally.

If your payload depends on Bash semantics, enable `ensure_bash`.  
Otherwise, the remote system’s default shell (often `ksh` on AIX) will interpret the script.

---

#### Local Execution (Optional)

If you want to test or run the payload locally before using it with `ssh_run.sh`, you can:

- execute it directly as a shell script:
  ```bash
  sh payload_file.sh
  ```
- or make it executable and run it:
  ```bash
  chmod +x payload_file.sh
  ./payload_file.sh
  ```

This allows quick validation without sending it to remote systems.

---

## 8. Disclaimer
Provided without warranty.  
Use only in controlled environments.  
User is responsible for validating payloads and outcomes.

---

## 9. Notes (Optional)

### Best Practices
- Run without payload first to verify connectivity and access  
- Keep payloads modular and predictable  
- Use FAILED host lists for controlled retry  
- Keep inventories tight and focused  

### Limitations
- Not an orchestration framework  
- Requires working SSH authentication  

---