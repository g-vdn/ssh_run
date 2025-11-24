# Payloads

This directory holds ready-to-use payloads for `ssh_run.sh`. Each script is
self-contained and can also be executed locally for validation.

## payload_generate_NFS_report
Inventories NFS mounts and autofs-managed entries on AIX and Linux, correlating
configuration with live mounts and enriching the output with filesystem usage.

**Usage**
```
./payload_generate_NFS_report [-d] > nfs_inventory.csv
```
`-d` enables verbose debug logging to stderr.

**CSV columns**
- `Hostname` – Short hostname (truncated before the first dot)
- `SID` – Parsed from `/etc/motd` when available, otherwise "-"
- `OS` – Operating system label (AIX or Linux)
- `NFS_Version` – NFS protocol version (e.g., 3, 4.1, unknown)
- `Is_Autofs` – `yes (active)`, `yes (inactive)`, or `no`
- `Mountpoint` – Local mountpoint path
- `Mount_Options` – Raw options from `/proc/mounts` or `nfsstat -m`
- `Mounted_From` – Remote NFS source (`server:/export/path`)
- `NFS_Server` – On AIX: whether this host exports the path; `NA` on Linux
- `Source_File` – Discovery source (mapfile, `/proc/mounts`, or `nfsstat`)
- `GB_blocks` – Filesystem size in gigabytes
- `Free_GB` – Free space in gigabytes
- `%Used` – Percentage of space used
- `Iused` – Inodes used
- `%Iused` – Percentage of inodes used

## payload_ping_test
Checks reachability to predefined IP targets, capturing site labels, source IP,
routing interface, gateway, and success status. The sample targets use
documentation IP ranges; replace them with your own hosts and optionally set a
`SITE_LABEL` environment variable to brand the site column in the output.

**Usage**
```
./payload_ping_test
```

**Output format**
`<hostname>|<os>|<site>|<source_ip>|<target_ip>|<label>|<gateway>|<route_iface>|<OK|NOK>`

## payload_template
A reference scaffold for new payloads, including optional Bash enforcement and
manual-run style logging helpers. Use it as a starting point when authoring new
payload scripts.
