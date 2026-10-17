# Lab Tools
A collection of useful lab tools.

## labcheck

[labcheck.sh](bin/labcheck.sh) is a script that checks which machines in your home lab are up and reachable, using the
nodes already listed in `/etc/hosts`, reporting their reachability and health based on specified levels. It includes options for customizing the check depth, timeout, SSH user, and more.

Tested on macOS (stock bash 3.2) and Linux. Target nodes can be macOS or Linux, including ARM-based embedded devices.

## Requirements

- `bash`, `ping`, `ssh`, `awk`, `sed` (all present by default on macOS and Linux)
- For levels 3 and 4: key-based SSH login to each node (ssh-agent, or a key without a passphrase). Password login is never attempted.
- macOS targets: **System Settings → General → Sharing → Remote Login** must be on.

## Install

```bash
chmod +x labcheck.sh
mkdir -p ~/bin && cp labcheck.sh ~/bin/labcheck   # make sure ~/bin is on your PATH
```

## Set up `/etc/hosts`

labcheck reads every IPv4 entry in `/etc/hosts` and automatically skips loopback (`127.*`), `0.0.0.0`, broadcast, IPv6, and Docker entries. The first hostname on each line is used as the node name and SSH target.

To be explicit about which entries are lab nodes, tag them with a comment and use `-g lab`:

```
10.0.0.10   mac-01      # lab
10.0.0.11   mac-02      # lab
10.0.0.20   linux-01    # lab
10.0.0.21   linux-02    # lab
10.0.0.30   device-01   # lab
10.0.0.31   device-02   # lab
```

Tip: `alias labcheck='labcheck -g lab'` in your shell rc.

## Usage

```
labcheck [options] [node ...]
```

With no node names, all nodes from `/etc/hosts` are checked. Name one or more nodes to check only those.

### Examples

```bash
labcheck                    # full check (level 4) of all nodes
labcheck -l 2               # quick check: ping + SSH port only
labcheck -l 3 device-01     # can I log in to device-01?
labcheck -g lab             # only lines tagged "# lab"
labcheck -s 10.0.0.         # only nodes in one subnet
labcheck -t 5               # longer timeout for slow networks
labcheck -u admin device-01 # log in as a specific user
NO_COLOR=1 labcheck         # plain output, no colors
```

### Options

| Option      | Description                                                      | Default      |
|-------------|------------------------------------------------------------------|--------------|
| `-l LEVEL`  | Check depth: `2`, `3` or `4` (see below)                         | `4`          |
| `-t SECS`   | Per-check timeout in whole seconds                               | `3`          |
| `-p PORT`   | SSH/TCP port to check (also passed to `ssh`)                     | `22`         |
| `-u USER`   | SSH user                                                         | `~/.ssh/config`, then current user |
| `-g TAG`    | Only nodes whose `/etc/hosts` line has a `# TAG` comment         | none         |
| `-s PREFIX` | Only nodes whose IP starts with `PREFIX`                         | none         |
| `-f FILE`   | Read a different hosts file                                      | `/etc/hosts` |
| `-h`        | Show help                                                        |              |

### Check levels

Each level includes the ones below it.

| Level | Checks                                    | A node counts as **up** when    |
|-------|-------------------------------------------|---------------------------------|
| 2     | ping, TCP connect to the SSH port         | the port is open                |
| 3     | + non-interactive SSH login               | the login succeeds              |
| 4     | + health summary collected over SSH       | the login succeeds              |

Ping is reported but never decides up/down on its own, because macOS stealth mode and some firewalls drop ICMP.

## Output

Example (level 4):

```
NODE       ADDRESS          PING  TCP:22    LOGIN    OS                ARCH     UP      LOAD       MEM   DISK  GPU
mac-01     10.0.0.10        no    open      ok       macOS 15.6        arm64    3d4h    1.92/12    61%   48%   -
linux-01   10.0.0.20        yes   open      ok       Ubuntu 24.04      x86_64   12d2h   0.31/16    22%   67%   -
device-01  10.0.0.30        yes   open      ok       Ubuntu 24.04      aarch64  5h12m   2.10/14    40%   81%   37%
device-02  10.0.0.31        no    timeout   skip

3/4 nodes up (level 4, timeout 3s)
```

### Columns

| Column  | Meaning                                                                   |
|---------|---------------------------------------------------------------------------|
| PING    | `yes` / `no`. Yellow `no` = ICMP blocked but the port answered            |
| TCP:22  | `open`, `closed` (connection refused), or `timeout` (no answer)          |
| LOGIN   | SSH login result (see below)                                              |
| OS      | OS name and version                                                       |
| ARCH    | CPU architecture                                                          |
| UP      | Uptime                                                                    |
| LOAD    | 1-minute load average / CPU count                                         |
| MEM     | Memory in use (yellow ≥ 75%, red ≥ 90%)                                   |
| DISK    | Root disk in use; on macOS the Data volume (yellow ≥ 75%, red ≥ 90%)      |
| GPU     | GPU utilization where the node reports it; `yes` if a GPU is present but gives no reading; `-` if none |

### LOGIN values

| Value     | Meaning                                                              | Fix                                                  |
|-----------|----------------------------------------------------------------------|------------------------------------------------------|
| `ok`      | Logged in                                                            |                                                      |
| `skip`    | Port wasn't open, so login wasn't tried                              | Node is down, or sshd isn't running                  |
| `auth`    | Key rejected or not available                                        | `ssh-copy-id <node>`, or `ssh-add` your key          |
| `hostkey` | Unknown or changed host key                                          | `ssh <node>` once by hand; or `ssh-keygen -R <node>` after a reflash |
| `refused` | Connection refused during login                                      | Check sshd on the node                               |
| `timeout` | Login or health command didn't finish in time                        | Try a larger `-t`                                    |
| `fail`    | Some other SSH error                                                 | Run `ssh -v <node>` to see why                       |

## Exit status

| Code | Meaning                                    |
|------|--------------------------------------------|
| `0`  | Every node is up at the chosen level       |
| `1`  | At least one node is down                  |
| `2`  | Usage error, or no nodes found             |

So it can gate other commands: `labcheck -l 2 -g lab && ./launch_training.sh`

## Notes

- All nodes are checked in parallel, so a run takes about one timeout regardless of node count (level 4 allows an extra 10 s for the SSH health command).
- SSH uses your `~/.ssh/config`, so per-host users, keys and jump hosts apply. Note that `-p` overrides any per-host `Port`, and the TCP check always uses `-p` (default 22).
- Only IPv4 entries are read.
