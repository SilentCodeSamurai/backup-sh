# backup-sh

A simple backup system for Ubuntu VPS: a server receives file uploads from one or more clients over HTTP. Clients are identified by connection IP. The server keeps files per client until total size exceeds a limit, then deletes oldest files when new uploads arrive.

## Requirements

- **Server**: `bash`, `socat` (`apt install socat`), standard GNU utils
- **Client**: `bash`, `curl`

## Quick start

**On the backup server (receiver)**

1. Create config: `./create-server-env.sh` (prompts for each variable; use `-f` to overwrite existing `server.env`).
2. Set at least `ACCESS_KEY` in `server.env` (or leave it from the prompt).
3. Run: `./server.sh`

**On a client VPS**

1. Create config: `./create-client-env.sh` (set `SERVER_URL`, `ACCESS_KEY` or `KEY_FILE`).
2. Upload a file or directory:
   - `./client.sh http://backup-server:9999 /path/to/file-or-dir`
   - Or set `SERVER_URL` in `client.env` and run: `./client.sh /path/to/file-or-dir`

## Configuration

| File | Purpose |
|------|--------|
| `server.env.template` | Template for server config (comments + variable names and defaults). |
| `client.env.template` | Template for client config. |
| `create-server-env.sh` | Interactive script: reads the server template, prompts for each value, writes `server.env`. |
| `create-client-env.sh` | Same for client, writes `client.env`. |

Both `server.sh` and `client.sh` load `server.env` and `client.env` respectively from the **script directory** if the file exists. You can also set variables in the environment; env overrides the `.env` file.

### Server (`server.env` / env)

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_ROOT` | `/var/backups/incoming` | Directory for all client backups (one subdir per client IP). |
| `PORT` | `9999` | TCP port to listen on. |
| `ACCESS_KEY` | (required) | Secret key; must match the key used by clients. |
| `MAX_SIZE_PER_CLIENT` | `1G` | Max total bytes per client (e.g. `1G`, `500M`, `100K`). Oldest files are deleted when a new upload would exceed this. |
| `LOG_FILE` | `/var/log/backup-server.log` | Server log path. |

### Client (`client.env` / env)

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_URL` | (optional) | Default server URL (e.g. `http://backup-server:9999`). Can be overridden by the first argument. |
| `ACCESS_KEY` | (optional) | Secret key; if empty, client uses `KEY_FILE` or `BACKUP_ACCESS_KEY` env. |
| `KEY_FILE` | `~/.backup-sh-key` | Path to file containing the access key (used when `ACCESS_KEY` is empty). |
| `LOG_FILE` | (empty) | If set, client logs are also appended to this file. |

## Server

- Run: `./server.sh` (no arguments). It starts `socat` and handles each connection with the same script in handler mode.
- Backups are stored under `BACKUP_ROOT/<client_ip>/` (IPv6 colons in the IP are replaced by `_`).
- When the total size for a client would exceed `MAX_SIZE_PER_CLIENT`, the server deletes oldest files (by mtime) until there is room, then writes the new file. A single file larger than the limit is allowed; all older files for that client are removed first.
- Logs go to `LOG_FILE` and (when run in foreground) to stderr.

## Client

- **Usage**: `./client.sh [server_url] <file_or_dir> [options]`
  - `server_url` — optional if `SERVER_URL` is set in `client.env`.
  - `file_or_dir` — file or directory; directories are sent recursively (paths relative to the directory root).
- **Options**: `--key-file PATH`, `--insecure` (curl `-k`).
- Logs go to stderr; if `LOG_FILE` is set in `client.env`, logs are also appended to that file.

## Security

- The server accepts uploads only when the `X-Access-Key` header matches `ACCESS_KEY`.
- The client is identified by the **connection source IP** (`SOCAT_PEERADDR` on the server); it is not sent by the client, so it cannot be spoofed.
- File paths are sanitized (no `..`, no leading `/`, limited character set) to avoid path traversal.

## Files in this repo

| File | Description |
|------|-------------|
| `server.sh` | Backup server (daemon + HTTP handler). |
| `client.sh` | Backup client (upload files or directories). |
| `server.env.template` | Server config template. |
| `client.env.template` | Client config template. |
| `create-server-env.sh` | Creates `server.env` from prompts. |
| `create-client-env.sh` | Creates `client.env` from prompts. |

After running the create scripts (or copying and editing templates), you will have `server.env` and/or `client.env` in the same directory; do not commit them if they contain secrets.
