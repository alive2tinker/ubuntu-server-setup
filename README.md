# Ubuntu 26.04 Strata inference station

Bootstrap a dedicated **Ubuntu Server 26.04 amd64 PC with a Radeon RX 7900 XTX**. The script installs SSH, Ubuntu's AMD driver/firmware and runtime dependencies, native Strata with its packaged HIP engine, and cloudflared. It configures boot services, a private inference account, authenticated API access, and GPU/inference checks.

The Strata release remains pinned to **v0.2.13**. This script targets the hardware and Ubuntu release above; it is not a generic installer for every AMD GPU or Linux distribution.

## Files to commit

- `ubuntu26-strata-setup.sh` — installer and management command.
- `.env.example` — documented public configuration template with blank credentials.
- `.gitignore` — excludes your private `.env` and common credential copies.
- `README.md` — this guide.

Create your real `.env` on the server. Do not commit it. The installer does not need your GitHub password or a GitHub token.

## Quick start

After installing and booting Ubuntu Server, put these four files in one directory. From that directory:

```bash
cp .env.example .env
chmod 600 .env
nano .env
sudo bash ./ubuntu26-strata-setup.sh --env-file ./.env
```

Use your preferred text editor if `nano` is unavailable. Supply the configuration below. The script reads the file itself, so `sudo -E`, `source .env`, and `export` are unnecessary. An adjacent `.env` is also loaded automatically when running `install` from the downloaded script. Explicit `--env-file` paths are resolved relative to the current directory.

Normal mode prompts for missing required values. With `CLOUDFLARE_MODE=local`, the first run prints an authorization URL for you to open on your Mac. Keep the server command running while completing authorization.

For a complete configuration that needs no terminal prompts:

```bash
sudo bash ./ubuntu26-strata-setup.sh --env-file ./.env --non-interactive
```

First-time unattended setup requires `remote` mode with a connector token, or `skip` mode. `local` mode can run unattended only after its Cloudflare account authorization certificate already exists. Unattended mode checks required settings before apt or account/service configuration. Downloads and hardware checks can still fail for environmental reasons.

## Configuration reference

| Variable | What to supply | Missing or blank behavior |
| --- | --- | --- |
| `SSH_USERNAME` | Your existing Ubuntu administrator username, or a new normal Linux username. | Interactive prompt; required for unattended installation. This account receives sudo access. |
| `SSH_PASSWORD` | The password you want for that account. Use quotes to preserve leading/trailing spaces. | In a supplied configuration, blank preserves an existing active password. A new or locked account prompts interactively; unattended setup requires a password. If the key is omitted entirely, interactive setup prompts. |
| `CLOUDFLARE_MODE` | `local`, `remote`, or `skip`. | Interactive prompt; an explicit choice is required unattended. The template selects `local`. |
| `CLOUDFLARE_HOSTNAME` | Your full public hostname, such as `strata.your-domain.com`. No scheme, port, path, or `/v1`. | Required for local/remote setup. Can reuse a previously saved hostname. |
| `CLOUDFLARE_TUNNEL_NAME` | Optional dedicated name for a locally managed tunnel. | Reuses the saved name, otherwise derives `strata-<hostname-with-dashes>`. Set a shorter name if that would exceed 100 characters. Ignored in remote/skip mode. |
| `CLOUDFLARE_TUNNEL_TOKEN` | The connector token for a remotely managed tunnel. | Local/skip mode needs none. First remote setup prompts; unattended setup requires it. A previous remote installation can reuse its stored token. |
| `INSTALL_MODEL` | `true` to prepare/download a model, or `false` to skip that stage. | Interactive prompt; an explicit choice is required for unattended install/model operations. **The template uses `true`, authorizing the download and replacement of any currently serving model.** |
| `STRATA_MODEL` | `iq2_xs`, `q2_0`, `iq3_xxs`, or `iq3_s`. | Initial default `iq2_xs`; later runs can reuse the saved choice. Interactive model selection is available when `INSTALL_MODEL` is omitted. |
| `STRATA_CONTEXT` | `8k`, `16k`, or `32k`. | Initial default `16k`; later runs can reuse the saved context. |

`INSTALL_MODEL=false` leaves the machine installed but does not download a first model. An existing model is preserved and may resume serving after installation. Large model downloads can exceed 80 GB; the script displays Strata's plan before beginning.

`CLOUDFLARE_MODE=skip` means skip reconfiguration and preserve any existing tunnel. It does not disable an existing tunnel. On a fresh installation, no public tunnel is configured.

Only these nine variable names are accepted. Unknown names, duplicates, malformed values, and invalid choices are rejected. Optional model/context choices and the tunnel name are not secrets.

## Which tunnel mode to choose

### Local: let the installer create the tunnel

Set `CLOUDFLARE_MODE=local` and your `CLOUDFLARE_HOSTNAME`. Leave the connector token empty. You authorize Cloudflare in your Mac's browser once, and the installer creates its dedicated named tunnel and DNS route. An optional `CLOUDFLARE_TUNNEL_NAME` makes that tunnel easy to recognize in your account.

The domain must be available in your Cloudflare account. The installer refuses to take over an unrelated existing tunnel name or overwrite an unrelated DNS record automatically.

### Remote: use a tunnel configured in Cloudflare

Create a cloudflared tunnel in the Cloudflare dashboard and copy its **connector token**. Put only the token into `CLOUDFLARE_TUNNEL_TOKEN`, and select `CLOUDFLARE_MODE=remote`.

In that same tunnel's dashboard, configure a published application with your hostname and origin:

```text
http://127.0.0.1:8080
```

The script installs and configures this PC's connector. The token alone does not configure the hostname-to-origin route in your Cloudflare account; you must save that route in the dashboard. See Cloudflare's [remote tunnel setup guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/) and [connector-token instructions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/).

Do not paste the whole `cloudflared service install ...` command into `.env`, and do not run that command separately. This installer creates its own `cloudflared-strata.service`.

Both modes start the connector only after a local model passes authentication and inference checks. Your API base URL is `https://YOUR_HOSTNAME/v1`.

## Passwords, tokens, and dotenv syntax

The parser reads `.env` as data. It never executes `source`, `eval`, variable interpolation, backticks, or command substitution from that file. Ordinary `$`, `#`, `=`, backslashes, and quotes inside values remain literal.

Matching outer single or double quotes are removed. Unquoted values have surrounding whitespace removed. Quoted values preserve surrounding whitespace. Backslash escape sequences are not decoded, so `\n` means the two literal characters, not a newline.

Put comments on their own lines beginning with `#`. Inline comments, multiline values, and `export KEY=...` are unsupported. For example, `SSH_PASSWORD=abc # comment` would set the literal password `abc # comment`.

The private `.env` must be a regular file owned by you or root, with no permissions for other users. The recommended mode is `0600`; symlinks and group/world-readable files are rejected. The installer does not print credentials or export the bootstrap settings to child processes. Password changes go to `chpasswd` through stdin; a tunnel token is stored in a private runtime file instead of process arguments.

The automatically generated Strata API key is separate from your SSH password and Cloudflare token. It is preserved across reruns. Retrieve it on the server with:

```bash
sudo strata-station key
```

Use it as your inference client's API key. It also grants Strata management access. The script does not copy your complete `.env` into the installed management command or save the SSH password in its nonsecret settings file. You may remove `.env` after installation if you no longer need it for repeat setup.

## GitHub workflow

Commit the four public files listed above. Verify your real configuration is ignored from the repository directory:

```bash
git check-ignore -v .env
git status --short
```

`.gitignore` does not untrack a file already committed. If `.env` is already tracked, remove it from the index with `git rm --cached -- .env`. If real credentials were pushed, replace those credentials; adding an ignore rule does not remove them from Git history. See [GitHub's ignore-file documentation](https://docs.github.com/en/get-started/git-basics/ignoring-files).

## After installation and reruns

The installed `strata-station` command is self-contained. Its normal maintenance commands do not automatically load `.env`:

```bash
sudo strata-station status
sudo strata-station check
sudo strata-station key
```

To deliberately reuse your private configuration for model or tunnel changes:

```bash
sudo strata-station model --env-file /absolute/path/to/.env
sudo strata-station tunnel --env-file /absolute/path/to/.env
```

These operations also accept `--non-interactive`. Alternatively omit `--env-file` to choose settings interactively. Do not pass `--env-file` to `status`, `check`, or `key`.

Re-running `install` reinstalls the pinned Strata release and intentionally reapplies any nonempty `SSH_PASSWORD`. Set it to an empty value to preserve the existing active password. `INSTALL_MODEL=true` intentionally prepares the chosen model and replaces the current serving profile. Set it to `false` to preserve the existing model. The server's generated API key and downloaded model files are retained.

The script does not reboot automatically. If firmware/kernel updates require a reboot, reboot when ready and run `sudo strata-station check`. If model setup was deferred, run the `model` command after GPU checks pass. Port 8080 stays on loopback; SSH and the named Cloudflare tunnel provide access.

## Validation and limits

The dotenv parser, configuration preflight, SSH configuration, API authentication/streaming checks, and GPU selection logic have offline fixture coverage. Provisioning operations were mocked in those tests; the script has not been executed on your PC. Installation performs real GPU access and HIP memory checks, followed by actual authenticated model inference before enabling the serving setup.

The GPU and service defaults remain the ones chosen for this station: RX 7900 XTX HIP backend, one inference request at a time, vision disabled, and port 8080. No additional driver URL, GPU override, ROCm version, Strata API key, or port setting is required in `.env`.
