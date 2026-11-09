#!/usr/bin/env bash
# Ubuntu Server 26.04 / Radeon RX 7900 XTX inference station
# Reviewed against Strata v0.2.13 (2026-11-09).
#
# RUN: sudo bash ubuntu26-strata-setup.sh --env-file .env
# Copy .env.example to .env, chmod 600 .env, then edit your private configuration.
# An adjacent .env is loaded automatically on install; missing values are prompted.
# The .env is parsed as literal data, never sourced or executed as shell code.
# --non-interactive fails if a required value is missing instead of prompting.
# Passwords and connector tokens belong only in the ignored, private .env file.
# Cloudflare: create a named tunnel using a browser authorization on your Mac,
# or supply an existing connector token and configure its hostname in Cloudflare.
# A domain on Cloudflare is required. Quick Tunnels are deliberately not used:
# https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/ (no SSE).
#
# Installs stock Ubuntu AMD driver/firmware + packaged HIP runtime, NOT a desktop,
# separate ROCm SDK, Docker, kernel hacks, overclock, or power-limit changes.
# Creates a private, non-login 'strata' account for inference. Your SSH account
# receives sudo membership. Existing home directories and SSH keys are preserved.
#
# Installed management command (run with sudo):
#   strata-station model     Select/download a model and enable boot-time serving
#   strata-station tunnel    Create/configure a named Cloudflare tunnel
#   strata-station check     GPU self-test + local auth/inference + remote checks
#   strata-station status    Service status, without printing credentials
#   strata-station key       Print your private Strata API key locally
#   strata-station model --env-file /path/to/.env
#   strata-station tunnel --env-file /path/to/.env
# Only install automatically reads .env; other commands require --env-file.
#
# Model downloads are optional during setup and can exceed 80 GB. A serving
# profile is enabled only after an actual local inference/authentication test.
# Re-running preserves the API key and model files, but can update the SSH
# password and reinstalls the pinned Strata release. It never reboots itself.
#
# Primary references:
# https://github.com/Niko1221/Strata/blob/v0.2.13/docs/AMD_HIP.md
# https://github.com/Niko1221/Strata/blob/v0.2.13/docs/TERMINAL.md
# https://github.com/Niko1221/Strata/blob/v0.2.13/docker/Dockerfile
# https://pkg.cloudflare.com/index.html
# https://developers.cloudflare.com/tunnel/reference/run-parameters/
# https://manpages.ubuntu.com/manpages/resolute/man5/sshd_config.5.html

set +x
set -Eeuo pipefail
umask 077

readonly STATION_DIR=/etc/strata-station
readonly STATION_HOME=/var/lib/strata
readonly STATION_CLI=/var/lib/strata/.local/bin/strata
readonly STATION_PROFILE=/var/lib/strata/.config/strata/profiles/launch-station.json
readonly STATION_API_ENV=/etc/strata-station/api.env
readonly STATION_GPU_ENV=/etc/strata-station/gpu.env
readonly STRATA_RELEASE=v0.2.13
readonly STRATA_RELEASE_FEED=https://github.com/Niko1221/Strata/releases/download/v0.2.13
readonly STRATA_INSTALLER_SHA256=d47754af1f74c95bf763e0b8d484232443466decd1a22d0be3208760a2f53822
readonly STATION_PORT=8080
readonly STATION_METRICS_PORT=20241

STATION_PHASE=initialization
STATION_LOGIN=''
STATION_MODEL=iq2_xs
STATION_CONTEXT=16k
STATION_CF_MODE=''
STATION_CF_HOST=''
STATION_CF_NAME=''
STATION_CF_ID=''
STATION_ANSWER=''
STATION_WORK=''
STATION_GPU_OK=0
STATION_SSH_ROLLBACK=''
STATION_NON_INTERACTIVE=0
declare -A STATION_CONFIG=()

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
on_error() {
    local error_code=$1 error_line=$2
    unset login_password login_confirm cf_token
    unset 'STATION_CONFIG[SSH_PASSWORD]' 'STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]'
    printf '\nFAILED during %s (line %s, exit %s).\n' "$STATION_PHASE" "$error_line" "$error_code" >&2
    printf 'No automatic reboot or destructive rollback was performed. Fix the reported error and rerun this command.\n' >&2
    exit "$error_code"
}
cleanup() {
    unset 'STATION_CONFIG[SSH_PASSWORD]' 'STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]'
    restore_ssh_if_pending
    [[ -z "$STATION_WORK" ]] || rm -rf -- "$STATION_WORK"
}
restore_ssh_if_pending() {
    if [[ -n "$STATION_SSH_ROLLBACK" ]]; then
        cp -a "$STATION_SSH_ROLLBACK/sshd_config" /etc/ssh/sshd_config || warn 'Could not restore the SSH main file.'
        if [[ -f "$STATION_SSH_ROLLBACK/snippet" ]]; then
            cp -a "$STATION_SSH_ROLLBACK/snippet" /etc/ssh/sshd_config.d/00-strata-station.conf || warn 'Could not restore the SSH snippet.'
        else
            rm -f /etc/ssh/sshd_config.d/00-strata-station.conf || warn 'Could not remove the pending SSH snippet.'
        fi
        warn "SSH configuration restored from $STATION_SSH_ROLLBACK."
        STATION_SSH_ROLLBACK=''
    fi
}
ask() {
    local label=$1 default_value=${2-}
    (( STATION_NON_INTERACTIVE == 0 )) || die "Missing configuration for: $label. Supply it in .env or run interactively."
    if [[ -n "$default_value" ]]; then
        printf '%s [%s]: ' "$label" "$default_value" >&3
    else
        printf '%s: ' "$label" >&3
    fi
    IFS= read -r STATION_ANSWER <&3 || die 'Interactive input ended.'
    [[ -n "$STATION_ANSWER" ]] || STATION_ANSWER=$default_value
}
ask_yes() {
    local label=$1 default_value=${2:-y}
    while :; do
        ask "$label (y/n)" "$default_value"
        case "$STATION_ANSWER" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
        esac
    done
}
valid_login() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] &&
        [[ "$1" != root && "$1" != strata && "$1" != nobody && "$1" != cloudflared ]]
}
valid_hostname() {
    python3 - "$1" <<'PY'
import re, sys
host = sys.argv[1]
labels = host.split('.')
valid = (len(host) <= 253 and len(labels) >= 2 and
         all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in labels) and
         not all(x.isdigit() for x in labels))
sys.exit(0 if valid else 1)
PY
}
load_dotenv() {
    local dotenv_path=$1 parsed_path="$STATION_WORK/dotenv.parsed" cfg_name cfg_value
    # Check the parser status before importing anything. Process substitution
    # would hide a parser failure and could apply only part of the configuration.
    if ! python3 - "$dotenv_path" > "$parsed_path" <<'PY'
import os, re, stat, sys
allowed = {
    'SSH_USERNAME', 'SSH_PASSWORD', 'CLOUDFLARE_MODE', 'CLOUDFLARE_HOSTNAME',
    'CLOUDFLARE_TUNNEL_NAME', 'CLOUDFLARE_TUNNEL_TOKEN', 'INSTALL_MODEL',
    'STRATA_MODEL', 'STRATA_CONTEXT',
}
def fail(message):
    print('Configuration error: ' + message, file=sys.stderr)
    raise SystemExit(1)
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        owners = {0, os.getuid()}
        if os.environ.get('SUDO_UID', '').isdigit():
            owners.add(int(os.environ['SUDO_UID']))
        if not stat.S_ISREG(info.st_mode):
            fail('.env must be a regular file, not a symlink or special file.')
        if info.st_uid not in owners:
            fail('.env must be owned by you or root.')
        if stat.S_IMODE(info.st_mode) & 0o077:
            fail('.env must be private. Run chmod 600 on your .env file.')
        data = stream.read(65537)
    if len(data) > 65536:
        fail('.env exceeds the 64 KiB size limit.')
    contents = data.decode('utf-8-sig')
except (OSError, UnicodeError):
    fail('Cannot read .env safely; use an accessible regular UTF-8 file, not a symlink.')
values = {}
for number, raw in enumerate(contents.split('\n'), 1):
    # Windows CRLF is accepted. A CR anywhere inside a value is rejected.
    if raw.endswith('\r'): raw = raw[:-1]
    if any(ord(c) < 32 and c != '\t' or ord(c) == 127 for c in raw):
        fail(f'Control character on line {number}.')
    line = raw.strip()
    if not line or line.startswith('#'): continue
    match = re.fullmatch(r'([A-Z][A-Z0-9_]*)\s*=\s*(.*)', line)
    if not match:
        fail(f'Expected KEY=value on line {number}; multiline values and export are unsupported.')
    key, value = match.groups()
    if key not in allowed:
        fail(f'Unknown configuration key on line {number}; check .env.example.')
    if key in values:
        fail(f'Duplicate {key} on line {number}.')
    value = value.strip()
    if value.startswith(('"', "'")):
        if len(value) < 2 or value[-1] != value[0]:
            fail(f'Unmatched quotes for {key} on line {number}; put comments on their own line.')
        value = value[1:-1]
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        fail(f'Control character in {key} on line {number}.')
    # No interpolation, escapes, command substitution, or inline comments.
    values[key] = value
for key, value in values.items():
    sys.stdout.buffer.write(key.encode() + b'\0' + value.encode() + b'\0')
PY
    then
        rm -f -- "$parsed_path"
        die 'The .env file was rejected; no configuration values were applied.'
    fi
    STATION_CONFIG=()
    while IFS= read -r -d '' cfg_name && IFS= read -r -d '' cfg_value; do
        STATION_CONFIG["$cfg_name"]=$cfg_value
    done < "$parsed_path"
    rm -f -- "$parsed_path"
    unset cfg_value
    say 'Loaded private .env configuration.'
}
valid_connector_token() {
    # stdin only: never put a connector token in a child process's arguments.
    python3 -c '
import base64, json, re, sys, uuid
try:
    token = sys.stdin.read().strip()
    if not re.fullmatch(r"[a-zA-Z0-9+/=]{40,}", token): raise ValueError()
    obj = json.loads(base64.b64decode(token, validate=True))
    if not isinstance(obj.get("a"), str) or not obj["a"]: raise ValueError()
    uuid.UUID(obj["t"])
    if len(base64.b64decode(obj["s"], validate=True)) < 16: raise ValueError()
except Exception:
    sys.exit(1)
'
}
validate_config() {
    local action=$1 cfg_login=${STATION_CONFIG[SSH_USERNAME]:-}
    local cfg_mode=${STATION_CONFIG[CLOUDFLARE_MODE]:-} cfg_host cfg_name account_uid account_shell root_profile_dir
    [[ -z "$cfg_login" ]] || valid_login "$cfg_login" || die 'Invalid SSH_USERNAME; use a normal lowercase Linux username.'
    case "$cfg_mode" in ''|local|remote|skip) ;; *) die 'CLOUDFLARE_MODE must be local, remote, or skip.' ;; esac
    case "${STATION_CONFIG[INSTALL_MODEL]:-}" in ''|true|false) ;; *) die 'INSTALL_MODEL must be true or false.' ;; esac
    case "${STATION_CONFIG[STRATA_MODEL]:-}" in ''|iq2_xs|q2_0|iq3_xxs|iq3_s) ;; *) die 'Invalid STRATA_MODEL; see .env.example.' ;; esac
    case "${STATION_CONFIG[STRATA_CONTEXT]:-}" in ''|8k|16k|32k) ;; *) die 'STRATA_CONTEXT must be 8k, 16k, or 32k.' ;; esac
    cfg_host=${STATION_CONFIG[CLOUDFLARE_HOSTNAME]:-}
    if [[ -n "$cfg_host" ]]; then
        STATION_CONFIG[CLOUDFLARE_HOSTNAME]=${cfg_host,,}
        valid_hostname "${cfg_host,,}" || die 'CLOUDFLARE_HOSTNAME must be a hostname without a scheme, port, or path.'
    fi
    cfg_name=${STATION_CONFIG[CLOUDFLARE_TUNNEL_NAME]:-}
    [[ -z "$cfg_name" || "$cfg_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$ ]] || die 'Invalid CLOUDFLARE_TUNNEL_NAME.'
    if [[ "$cfg_mode" == local && -z "$cfg_name" && -n ${cfg_host:-$STATION_CF_HOST} ]]; then
        cfg_host=${cfg_host:-$STATION_CF_HOST}
        cfg_name=${STATION_CF_NAME:-strata-${cfg_host//./-}}
        [[ "$cfg_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$ ]] ||
            die 'The automatic tunnel name would be too long. Set a shorter CLOUDFLARE_TUNNEL_NAME.'
    fi
    if [[ -n ${STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]:-} ]]; then
        printf '%s' "${STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]}" | valid_connector_token ||
            die 'CLOUDFLARE_TUNNEL_TOKEN must be a tunnel connector token, not an account API token.'
    fi
    if [[ "$action" == install ]]; then
        if [[ -z "$cfg_login" && $STATION_NON_INTERACTIVE == 1 ]]; then
            die 'Set SSH_USERNAME for a non-interactive installation.'
        fi
        if [[ -n "$cfg_login" ]] && id "$cfg_login" >/dev/null 2>&1; then
            account_uid=$(id -u "$cfg_login")
            account_shell=$(getent passwd "$cfg_login" | cut -d: -f7)
            (( account_uid >= 1000 && account_uid < 65534 )) &&
                [[ -x "$account_shell" && "$account_shell" != */nologin && "$account_shell" != */false ]] ||
                die 'SSH_USERNAME refers to a system account or an account without an interactive shell.'
        fi
        if (( STATION_NON_INTERACTIVE == 1 )); then
            if [[ -z ${STATION_CONFIG[SSH_PASSWORD]:-} ]]; then
                if ! id "$cfg_login" >/dev/null 2>&1 || [[ $(passwd -S "$cfg_login" | awk '{print $2}') != P ]]; then
                    die 'Set SSH_PASSWORD for a new account or an account without an active password.'
                fi
            fi
            [[ -n ${STATION_CONFIG[INSTALL_MODEL]:-} ]] || die 'Set INSTALL_MODEL=true or false for a non-interactive installation.'
        fi
    fi
    if [[ "$action" == model && $STATION_NON_INTERACTIVE == 1 && -z ${STATION_CONFIG[INSTALL_MODEL]:-} ]]; then
        die 'Set INSTALL_MODEL=true or false for non-interactive model setup.'
    fi
    if [[ "$action" == install || "$action" == tunnel ]]; then
        if (( STATION_NON_INTERACTIVE == 1 )); then
            [[ -n "$cfg_mode" ]] || die 'Set CLOUDFLARE_MODE=local, remote, or skip for non-interactive setup.'
            if [[ "$cfg_mode" != skip ]]; then
                [[ -n ${STATION_CONFIG[CLOUDFLARE_HOSTNAME]:-$STATION_CF_HOST} ]] || die 'Set CLOUDFLARE_HOSTNAME.'
            fi
            if [[ "$cfg_mode" == local && ! -s "$STATION_DIR/cloudflare-cert.pem" ]]; then
                root_profile_dir=$(getent passwd root | cut -d: -f6)
                [[ -s "$root_profile_dir/.cloudflared/cert.pem" ]] ||
                    die 'First-time local tunnel authorization needs a browser. Omit --non-interactive or use remote mode with a connector token.'
            fi
            if [[ "$cfg_mode" == remote && -z ${STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]:-} ]]; then
                if [[ "$STATION_CF_MODE" != remote || ! -s "$STATION_DIR/cloudflare-token" ]] ||
                    ! valid_connector_token < "$STATION_DIR/cloudflare-token"; then
                    die 'Set CLOUDFLARE_TUNNEL_TOKEN for the first remote tunnel setup.'
                fi
            fi
        fi
    fi
}
load_settings() {
    if [[ -f "$STATION_DIR/settings.conf" ]]; then
        [[ $(stat -c '%u' "$STATION_DIR/settings.conf") == 0 ]] || die 'Settings must be owned by root.'
        # This is our root-owned, mode-0600 settings file; it contains no secrets.
        # shellcheck disable=SC1091
        source "$STATION_DIR/settings.conf"
    fi
}
save_settings() {
    local settings_tmp
    settings_tmp=$(mktemp "$STATION_DIR/settings.XXXXXX")
    {
        printf 'STATION_LOGIN=%q\n' "$STATION_LOGIN"
        printf 'STATION_MODEL=%q\n' "$STATION_MODEL"
        printf 'STATION_CONTEXT=%q\n' "$STATION_CONTEXT"
        printf 'STATION_CF_MODE=%q\n' "$STATION_CF_MODE"
        printf 'STATION_CF_HOST=%q\n' "$STATION_CF_HOST"
        printf 'STATION_CF_NAME=%q\n' "$STATION_CF_NAME"
        printf 'STATION_CF_ID=%q\n' "$STATION_CF_ID"
    } > "$settings_tmp"
    chmod 0600 "$settings_tmp"
    mv -f -- "$settings_tmp" "$STATION_DIR/settings.conf"
}
as_strata() {
    # runuser supplies the service account's real home and supplementary groups.
    # Read the API key inside that account's shell, never through env's argv.
    runuser -u strata -- /bin/bash -c '
        set -e
        cd /var/lib/strata
        for station_env_name in "${!STRATA_@}" "${!XDG_@}"; do
            [ -z "$station_env_name" ] || unset "$station_env_name"
        done
        unset HIP_VISIBLE_DEVICES ROCR_VISIBLE_DEVICES HSA_OVERRIDE_GFX_VERSION
        export XDG_CONFIG_HOME=/var/lib/strata/.config
        export XDG_STATE_HOME=/var/lib/strata/.local/state
        export XDG_DATA_HOME=/var/lib/strata/.local/share
        set -a
        . /etc/strata-station/api.env
        if [ -f /etc/strata-station/gpu.env ]; then . /etc/strata-station/gpu.env; fi
        set +a
        exec "$@"
    ' strata-station "$@"
}
require_host() {
    [[ $EUID == 0 ]] || die 'Run this command with sudo.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]] || die 'This script targets Ubuntu Server 26.04 LTS only.'
    [[ $(dpkg --print-architecture) == amd64 ]] || die 'This script targets an x86-64/amd64 PC.'
    [[ -d /run/systemd/system ]] || die 'Boot the installed server first; a chroot/container is not supported.'
}
install_packages() {
    STATION_PHASE='Ubuntu packages and firmware'
    say 'Updating Ubuntu and installing SSH, AMD firmware, and runtime libraries'
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold -y upgrade
    apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \
        openssh-server sudo ufw curl ca-certificates python3 jq openssl \
        pciutils kmod util-linux xz-utils tar \
        linux-generic linux-firmware-amd-graphics \
        libstdc++6 libgomp1 libatomic1 libnuma1 zlib1g \
        libdrm2 libdrm-amdgpu1 libelf1t64 libtinfo6 libpci3
}
configure_login() {
    STATION_PHASE='SSH login account'
    local default_login=${STATION_LOGIN:-${SUDO_USER:-}}
    local login_password='' login_confirm='' existing_account=0 login_uid login_shell password_state
    [[ "$default_login" != root ]] || default_login=''
    while :; do
        if [[ -n ${STATION_CONFIG[SSH_USERNAME]:-} ]]; then
            STATION_ANSWER=${STATION_CONFIG[SSH_USERNAME]}
        else
            ask 'SSH administrator username' "$default_login"
        fi
        valid_login "$STATION_ANSWER" || { warn 'Use a normal lowercase Linux username, not a system account.'; continue; }
        STATION_LOGIN=$STATION_ANSWER
        if id "$STATION_LOGIN" >/dev/null 2>&1; then
            login_uid=$(id -u "$STATION_LOGIN")
            (( login_uid >= 1000 && login_uid < 65534 )) || { warn 'An existing system account cannot be used.'; continue; }
            login_shell=$(getent passwd "$STATION_LOGIN" | cut -d: -f7)
            if [[ ! -x "$login_shell" || "$login_shell" == */nologin || "$login_shell" == */false ]]; then
                warn 'That account has no usable interactive login shell. Choose a normal login account.'
                continue
            fi
            existing_account=1
        fi
        break
    done
    printf '\nThis login receives sudo access. Existing SSH keys and home files are preserved.\n' >&3
    password_state=''
    if (( existing_account == 1 )); then password_state=$(passwd -S "$STATION_LOGIN" | awk '{print $2}'); fi
    if [[ -n ${STATION_CONFIG[SSH_PASSWORD]:-} ]]; then
        login_password=${STATION_CONFIG[SSH_PASSWORD]}
    elif [[ ( ${STATION_CONFIG[SSH_PASSWORD]+present} || $STATION_NON_INTERACTIVE == 1 ) && "$password_state" == P ]]; then
        say 'Keeping the existing account password.'
    else
        (( STATION_NON_INTERACTIVE == 0 )) || die 'Set SSH_PASSWORD for this account.'
        (( existing_account == 0 )) || printf 'Leave the password empty to keep an existing active password.\n' >&3
        while :; do
            printf 'SSH password (hidden): ' >&3
            IFS= read -r -s login_password <&3 || die 'Password input ended.'
            printf '\n' >&3
            if [[ -z "$login_password" && $existing_account == 1 ]]; then
                if [[ "$password_state" == P ]]; then break; fi
                warn 'This account has a locked or missing password. Enter a new password to enable password login.'
                continue
            fi
            [[ -n "$login_password" && "$login_password" != *$'\r'* ]] || { warn 'Enter a nonempty password without carriage returns.'; continue; }
            printf 'Repeat password (hidden): ' >&3
            IFS= read -r -s login_confirm <&3 || die 'Password input ended.'
            printf '\n' >&3
            [[ "$login_password" == "$login_confirm" ]] && break
            warn 'Passwords did not match.'
        done
    fi
    if (( existing_account == 0 )); then
        useradd --create-home --user-group --shell /bin/bash "$STATION_LOGIN"
    fi
    usermod -aG sudo "$STATION_LOGIN"
    if [[ -n "$login_password" ]]; then
        printf '%s:%s\n' "$STATION_LOGIN" "$login_password" | chpasswd
    fi
    unset login_password login_confirm
    unset 'STATION_CONFIG[SSH_PASSWORD]'
    save_settings
}
configure_ssh() {
    STATION_PHASE='SSH configuration'
    say 'Configuring password login for your account and validating SSH before reload'
    local ssh_backup ssh_effective root_effective ssh_port
    ssh_backup="/var/backups/strata-station/ssh-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 0700 "$ssh_backup"
    install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
    cp -a /etc/ssh/sshd_config "$ssh_backup/sshd_config"
    if [[ -f /etc/ssh/sshd_config.d/00-strata-station.conf ]]; then
        cp -a /etc/ssh/sshd_config.d/00-strata-station.conf "$ssh_backup/snippet"
    fi
    STATION_SSH_ROLLBACK=$ssh_backup
    cat > /etc/ssh/sshd_config.d/00-strata-station.conf <<'SSH_GLOBAL'
# Managed by strata-station. Per-user password permission is at the END of sshd_config.
PermitRootLogin no
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
SSH_GLOBAL
    chmod 0644 /etc/ssh/sshd_config.d/00-strata-station.conf
    python3 - "$STATION_LOGIN" <<'PY'
from pathlib import Path
import os, re, stat, sys, tempfile
p = Path('/etc/ssh/sshd_config')
text = p.read_text()
start, end = '# BEGIN STRATA STATION LOGIN', '# END STRATA STATION LOGIN'
text = re.sub(r'(?ms)^' + re.escape(start) + r'\n.*?^' + re.escape(end) + r'\n?', '', text)
if not re.search(r'(?mi)^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf\s*$', text):
    text = 'Include /etc/ssh/sshd_config.d/*.conf\n' + text
text = text.rstrip() + '\n\n' + start + '\n'
text += 'Match User ' + sys.argv[1] + '\n    PasswordAuthentication yes\n    PubkeyAuthentication yes\n    AuthenticationMethods any\nMatch all\n' + end + '\n'
old = p.stat()
with tempfile.NamedTemporaryFile('w', dir=p.parent, delete=False) as candidate:
    candidate.write(text)
    candidate.flush()
    os.fsync(candidate.fileno())
    candidate_path = candidate.name
os.chmod(candidate_path, stat.S_IMODE(old.st_mode))
os.chown(candidate_path, old.st_uid, old.st_gid)
os.replace(candidate_path, p)
PY
    ssh-keygen -A
    if /usr/sbin/sshd -t; then
        ssh_effective=$(/usr/sbin/sshd -T -C "user=$STATION_LOGIN,host=localhost,addr=127.0.0.1")
        root_effective=$(/usr/sbin/sshd -T -C 'user=root,host=localhost,addr=127.0.0.1')
    else
        ssh_effective='invalid'
        root_effective='invalid'
    fi
    if ! grep -Fxq 'passwordauthentication yes' <<< "$ssh_effective" ||
       ! grep -Fxq 'pubkeyauthentication yes' <<< "$ssh_effective" ||
       ! grep -Fxq 'authenticationmethods any' <<< "$ssh_effective" ||
       ! grep -Fxq 'permitemptypasswords no' <<< "$ssh_effective" ||
       ! grep -Fxq 'permitrootlogin no' <<< "$root_effective" ||
       grep -Eq '^(allowusers|denyusers|allowgroups|denygroups) ' <<< "$ssh_effective"; then
        restore_ssh_if_pending
        die "SSH validation found conflicting settings/access lists. Configuration restored from $ssh_backup; review existing SSH policy."
    fi
    # Allow every configured SSH port BEFORE enabling the firewall. No rule reset.
    while read -r ssh_port; do
        [[ "$ssh_port" =~ ^[0-9]+$ ]] || die 'Unexpected SSH port.'
        ufw insert 1 allow "$ssh_port/tcp" comment 'SSH administration'
    done < <({
        awk '$1 == "port" {print $2}' <<< "$ssh_effective"
        if [[ -n ${SSH_CONNECTION:-} ]]; then awk '{print $4}' <<< "$SSH_CONNECTION"; fi
        systemctl show ssh.socket --property=Listen --value 2>/dev/null |
            python3 -c 'import re,sys; print("\n".join(re.findall(r"(?:\]:|:|^)(\d+)\s+\(Stream\)", sys.stdin.read())))'
    } | awk '/^[0-9]+$/ && !seen[$0]++')
    if ! LC_ALL=C ufw status | grep -q '^Status: active'; then
        ufw default deny incoming
        ufw default allow outgoing
    fi
    ufw --force enable
    systemctl daemon-reload
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket; then
        systemctl enable --now ssh.socket
        if systemctl is-active --quiet ssh.service; then systemctl reload ssh.service; fi
    else
        systemctl enable --now ssh.service
        systemctl reload ssh.service
    fi
    STATION_SSH_ROLLBACK=''
    say "SSH configured for $STATION_LOGIN; root SSH login disabled. Backup: $ssh_backup"
}
configure_service_account() {
    STATION_PHASE='Private inference account'
    if id strata >/dev/null 2>&1; then
        [[ $(getent passwd strata | cut -d: -f6) == "$STATION_HOME" && $(id -u strata) -lt 1000 ]] ||
            die 'An unrelated strata account already exists. Refusing to repurpose it.'
    else
        useradd --system --user-group --create-home --home-dir "$STATION_HOME" --shell /usr/sbin/nologin strata
    fi
    getent group render >/dev/null || groupadd --system render
    getent group video >/dev/null || groupadd --system video
    usermod -aG render,video strata
    chmod 0700 "$STATION_HOME"
    install -d -o strata -g strata -m 0700 "$STATION_HOME/models" "$STATION_HOME/.local/bin"
    if [[ ! -s "$STATION_API_ENV" ]]; then
        printf 'STRATA_API_KEY=%s\n' "$(openssl rand -hex 32)" > "$STATION_API_ENV"
    fi
    chown root:strata "$STATION_API_ENV"
    chmod 0640 "$STATION_API_ENV"
    grep -Eq '^STRATA_API_KEY=[a-f0-9]{64}$' "$STATION_API_ENV" || die 'Unexpected API-key file format; refusing to overwrite it.'
    cat > /etc/security/limits.d/90-strata-station.conf <<'LIMITS'
strata soft memlock unlimited
strata hard memlock unlimited
strata soft nofile 65536
strata hard nofile 65536
LIMITS
    chmod 0644 /etc/security/limits.d/90-strata-station.conf
}
install_cloudflared() {
    STATION_PHASE='Cloudflare package installation'
    say 'Installing cloudflared from its signed official stable repository'
    curl --proto '=https' --tlsv1.2 -fLsS --retry 3 \
        https://pkg.cloudflare.com/cloudflare-main.gpg -o "$STATION_WORK/cloudflare-main.gpg"
    install -m 0644 "$STATION_WORK/cloudflare-main.gpg" /usr/share/keyrings/cloudflare-main.gpg
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
        > /etc/apt/sources.list.d/strata-cloudflared.list
    chmod 0644 /etc/apt/sources.list.d/strata-cloudflared.list
    apt-get -o DPkg::Lock::Timeout=120 update
    apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends cloudflared
    cloudflared --version
}
write_station_service() {
    STATION_PHASE='Boot service configuration'
    cat > /etc/systemd/system/strata.service <<'STRATA_UNIT'
[Unit]
Description=Strata inference server (RX 7900 XTX)
Wants=network-online.target
After=network-online.target
ConditionPathExists=/var/lib/strata/.config/strata/profiles/launch-station.json
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
User=strata
Group=strata
SupplementaryGroups=render video
WorkingDirectory=/var/lib/strata
EnvironmentFile=/etc/strata-station/api.env
EnvironmentFile=-/etc/strata-station/gpu.env
Environment=XDG_CONFIG_HOME=/var/lib/strata/.config
Environment=XDG_STATE_HOME=/var/lib/strata/.local/state
Environment=XDG_DATA_HOME=/var/lib/strata/.local/share
ExecStart=/var/lib/strata/.local/bin/strata serve --profile launch-station --host 127.0.0.1 --port 8080 --parallel 1 --output jsonl --offline --shutdown-timeout 30
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStopSec=90
LimitMEMLOCK=infinity
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
STRATA_UNIT
    chmod 0644 /etc/systemd/system/strata.service
    # Do not use PrivateDevices, MemoryDenyWriteExecute, or MemoryHigh for HIP.
    systemctl daemon-reload
    systemctl set-default multi-user.target
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
}
install_strata() {
    STATION_PHASE='Strata terminal installation'
    stop_tunnel
    systemctl disable --now strata.service
    if [[ -x "$STATION_CLI" ]]; then
        as_strata "$STATION_CLI" launch --stop --preset station >/dev/null 2>&1 || true
    fi
    say "Installing Strata $STRATA_RELEASE as the unprivileged inference account"
    curl --proto '=https' --tlsv1.2 -fLsS --retry 3 \
        "$STRATA_RELEASE_FEED/install.sh" -o "$STATION_WORK/install-strata.sh"
    printf '%s  %s\n' "$STRATA_INSTALLER_SHA256" "$STATION_WORK/install-strata.sh" | sha256sum --check --status
    install -o strata -g strata -m 0700 "$STATION_WORK/install-strata.sh" "$STATION_HOME/.install-strata.sh"
    as_strata env STRATA_FEED="$STRATA_RELEASE_FEED" \
        STRATA_DATA_DIR="$STATION_HOME/.local/share/strata" STRATA_BIN_DIR="$STATION_HOME/.local/bin" \
        sh "$STATION_HOME/.install-strata.sh"
    rm -f "$STATION_HOME/.install-strata.sh"
    as_strata "$STATION_CLI" --version
    STATION_PHASE='AMD HIP engine installation'
    say 'Installing the matching signed hip-rx7900 engine, independently of model weights'
    as_strata "$STATION_CLI" update --backend hip-rx7900 --no-control --feed "$STRATA_RELEASE_FEED" --yes
}
gpu_check() {
    STATION_PHASE='AMD compute verification'
    say 'Checking device access and running a memory round-trip through the packaged HIP runtime'
    local gpu_ordinal gpu_tmp
    modprobe amdgpu || return 1
    if [[ ! -c /dev/kfd ]]; then
        warn '/dev/kfd is missing. Reboot after the kernel/firmware update, then run sudo strata-station check.'
        return 1
    fi
    if ! runuser -u strata -- test -r /dev/kfd || ! runuser -u strata -- test -w /dev/kfd; then
        warn 'The strata service account cannot read/write /dev/kfd.'
        return 1
    fi
    if ! gpu_ordinal=$(as_strata python3 - "$STATION_CLI" <<'PY'
import json, os, pathlib, re, subprocess, sys
try:
    info = json.loads(subprocess.check_output([sys.argv[1], 'components', 'engines', '--output', 'json'], text=True))
    engines = [e for f in info.get('families', []) for e in f.get('engines', [])
               if e.get('backend') == 'hip' and e.get('variant') == 'rx7900' and e.get('active')]
    if not engines:
        raise RuntimeError('No active hip-rx7900 package found.')
    package = pathlib.Path(engines[0]['path'])
    metadata = json.loads((package / 'BUILD.json').read_text()) if (package / 'BUILD.json').is_file() else {}
    libdirs = [str(package)]
    for rel in metadata.get('lib_dirs', []):
        candidate = package / rel
        if candidate.is_dir(): libdirs.append(str(candidate))
    env = os.environ.copy()
    env.pop('HIP_VISIBLE_DEVICES', None)
    env.pop('ROCR_VISIBLE_DEVICES', None)
    env['LD_LIBRARY_PATH'] = ':'.join(libdirs)
    libraries = sorted(package.rglob('libamdhip64.so*'))
    if not libraries: raise RuntimeError('The HIP package has no libamdhip64 runtime.')
    # strata-device is optional in upstream Linux packages. Use HIP's stable C
    # interface instead. A child Python process gets the library path at startup.
    hip_code = r'''
import ctypes as c, json, re, sys
hip = c.CDLL(sys.argv[1])
def bind(name, args, result=c.c_int):
    fn = getattr(hip, name)
    fn.argtypes, fn.restype = args, result
    return fn
errstr = bind('hipGetErrorString', [c.c_int], c.c_char_p)
def check(code, operation):
    if code:
        detail = errstr(code)
        raise RuntimeError(operation + ': ' + (detail.decode() if detail else str(code)))
init = bind('hipInit', [c.c_uint])
count_devices = bind('hipGetDeviceCount', [c.POINTER(c.c_int)])
name_device = bind('hipDeviceGetName', [c.c_void_p, c.c_int, c.c_int])
set_device = bind('hipSetDevice', [c.c_int])
memory_info = bind('hipMemGetInfo', [c.POINTER(c.c_size_t), c.POINTER(c.c_size_t)])
allocate = bind('hipMalloc', [c.POINTER(c.c_void_p), c.c_size_t])
copy = bind('hipMemcpy', [c.c_void_p, c.c_void_p, c.c_size_t, c.c_int])
free = bind('hipFree', [c.c_void_p])
check(init(0), 'hipInit')
count = c.c_int()
check(count_devices(c.byref(count)), 'hipGetDeviceCount')
selected = None
for ordinal in range(count.value):
    name = c.create_string_buffer(256)
    check(name_device(name, len(name), ordinal), 'hipDeviceGetName')
    label = name.value.decode(errors='replace')
    print('HIP device ' + str(ordinal) + ': ' + label, file=sys.stderr)
    if re.search(r'7900\s*XTX\b', label, re.I): selected = ordinal
if selected is None:
    raise RuntimeError('HIP did not enumerate the expected RX 7900 XTX; refusing an iGPU or CPU-only fallback.')
check(set_device(selected), 'hipSetDevice')
available, total = c.c_size_t(), c.c_size_t()
check(memory_info(c.byref(available), c.byref(total)), 'hipMemGetInfo')
print('RX 7900 XTX / gfx1100: %.2f GiB VRAM, %.2f GiB currently free' %
      (total.value / 2**30, available.value / 2**30), file=sys.stderr)
pointer = c.c_void_p()
check(allocate(c.byref(pointer), 64 * 1024 * 1024), 'hipMalloc(64 MiB)')
try:
    source = (c.c_ubyte * 4096)(*[(i * 37 + 11) % 256 for i in range(4096)])
    target = (c.c_ubyte * 4096)()
    check(copy(pointer, source, len(source), 1), 'hipMemcpy host to device')
    check(copy(target, pointer, len(target), 2), 'hipMemcpy device to host')
    if bytes(source) != bytes(target): raise RuntimeError('HIP memory round-trip returned different bytes.')
finally:
    check(free(pointer), 'hipFree')
print(json.dumps({'ordinal': selected, 'total_vram': total.value, 'memory_roundtrip': True}))
'''
    result = json.loads(subprocess.check_output([sys.executable, '-c', hip_code, str(libraries[0])], env=env, text=True, timeout=120))
    if result.get('memory_roundtrip') is not True: raise RuntimeError('GPU memory test failed.')
    print(result['ordinal'])
except Exception as exc:
    print('GPU verification failed: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
    ); then
        warn 'GPU compute has not passed validation. Check driver/firmware, permissions, and the Strata package.'
        return 1
    fi
    [[ "$gpu_ordinal" =~ ^[0-9]+$ ]] || return 1
    gpu_tmp=$(mktemp "$STATION_DIR/gpu.XXXXXX") || return 1
    printf 'HIP_VISIBLE_DEVICES=%s\n' "$gpu_ordinal" > "$gpu_tmp" || return 1
    chmod 0644 "$gpu_tmp" || return 1
    mv -f -- "$gpu_tmp" "$STATION_GPU_ENV" || return 1
    STATION_GPU_OK=1
    say "HIP self-test passed for gfx1100 (HIP ordinal $gpu_ordinal). This is not a speed benchmark."
}
api_check() {
    # Modes: wait, local, remote. Keys are read from a file, never curl arguments.
    local check_mode=$1 check_url=${2:-http://127.0.0.1:8080}
    python3 - "$check_mode" "$check_url" "$STATION_API_ENV" <<'PY'
import json, pathlib, sys, time, urllib.error, urllib.request
mode, base, keyfile = sys.argv[1:]
key = pathlib.Path(keyfile).read_text().strip().split('=', 1)[1]
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
# Never forward a bearer credential to a redirected origin or an ambient proxy.
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
def request(path, auth=False, data=None, timeout=15):
    headers = {'Accept': 'application/json'}
    if auth: headers['Authorization'] = 'Bearer ' + key
    body = None if data is None else json.dumps(data).encode()
    if body is not None: headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(base.rstrip('/') + path, data=body, headers=headers)
    try:
        with opener.open(req, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, b''
if mode == 'wait':
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        try:
            code, body = request('/health', timeout=5)
            data = json.loads(body)
            if code == 200 and data.get('service') == 'strata' and data.get('loaded') is True:
                print('The Strata model is loaded.')
                sys.exit(0)
        except Exception:
            pass
        time.sleep(3)
    sys.exit('Model did not become ready within 15 minutes; inspect journalctl -u strata.service.')
try:
    code, _ = request('/v1/models')
    if code != 401:
        raise RuntimeError('Unauthenticated /v1/models returned HTTP ' + str(code) + ', expected 401. Tunnel will not be started.')
    code, body = request('/v1/models', auth=True)
    models = json.loads(body).get('data', []) if code == 200 else []
    if not models or not models[0].get('id'):
        raise RuntimeError('Authenticated model listing failed.')
    if mode == 'local':
        code, body = request('/v1/chat/completions', auth=True, timeout=300, data={
            'model': models[0]['id'], 'messages': [{'role': 'user', 'content': 'Say hello.'}],
            'max_tokens': 32, 'stream': False, 'temperature': 0})
        result = json.loads(body) if code == 200 else {}
        choices = result.get('choices', [])
        message = choices[0].get('message', {}) if choices else {}
        tokens = result.get('usage', {}).get('completion_tokens', 0)
        if not choices or not (tokens > 0 or message.get('content') or message.get('reasoning_content')):
            raise RuntimeError('Authenticated generation did not produce a completion.')
        print('PASS: missing-key requests rejected; authenticated local generation works.')
    else:
        code, body = request('/v1/chat/completions', auth=True, timeout=300, data={
            'model': models[0]['id'], 'messages': [{'role': 'user', 'content': 'Say hello.'}],
            'max_tokens': 32, 'stream': True, 'temperature': 0})
        generated = False
        for line in body.splitlines():
            if not line.startswith(b'data:') or line[5:].strip() == b'[DONE]': continue
            packet = json.loads(line[5:].strip())
            for item in packet.get('choices', []):
                delta = item.get('delta', {})
                generated = generated or bool(delta.get('content') or delta.get('reasoning_content'))
        if code != 200 or not generated or b'[DONE]' not in body:
            raise RuntimeError('HTTPS streaming inference did not complete successfully.')
        print('PASS: HTTPS tunnel enforces the API key and delivers a completed SSE response.')
except Exception as exc:
    print('API verification failed: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
}
stop_tunnel() {
    if [[ -f /etc/systemd/system/cloudflared-strata.service ]]; then
        systemctl disable --now cloudflared-strata.service
    fi
}
start_tunnel_if_ready() {
    [[ -f /etc/systemd/system/cloudflared-strata.service ]] || return 0
    if [[ ! -f "$STATION_PROFILE" ]] || ! api_check local; then
        warn 'Tunnel is configured but remains stopped until a model passes authentication and inference checks.'
        return 0
    fi
    systemctl reset-failed cloudflared-strata.service || true
    systemctl enable --now cloudflared-strata.service
    if [[ -n "$STATION_CF_HOST" ]]; then
        if ! api_check remote "https://$STATION_CF_HOST"; then
            warn 'Local inference passed, but the public hostname is not verified yet. DNS propagation, a missing remote route, or Cloudflare Access can cause this. Run sudo strata-station check again.'
        fi
    fi
}
configure_model() {
    STATION_PHASE='Model preparation'
    if [[ ${STATION_CONFIG[INSTALL_MODEL]:-} == false ]]; then
        say 'Model preparation skipped by INSTALL_MODEL=false; an existing model is preserved.'
        return 0
    fi
    [[ -x "$STATION_CLI" ]] || die 'Run the installer first.'
    gpu_check || die 'Fix GPU verification before downloading/starting the model.'
    local ram_gib free_gib choice
    ram_gib=$(awk '/MemTotal:/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
    free_gib=$(df --output=avail -B1 "$STATION_HOME/models" | awk 'NR==2 {printf "%.0f", $1/1073741824}')
    say "Model storage: $STATION_HOME/models; RAM: approximately $ram_gib GiB; free storage: approximately $free_gib GiB"
    if [[ -n ${STATION_CONFIG[STRATA_MODEL]:-} ]]; then
        STATION_MODEL=${STATION_CONFIG[STRATA_MODEL]}
    elif [[ $STATION_NON_INTERACTIVE == 0 && ${STATION_CONFIG[INSTALL_MODEL]:-} != true ]]; then
        cat >&3 <<'MODEL_MENU'
Qwen3.8-Flash-Next packs supported by the RX 7900 XTX:
  1) iq2_xs  - balanced starting point (default)
  2) q2_0    - smaller/faster
  3) iq3_xxs - larger; allow sufficient system RAM
  4) iq3_s   - largest of these; approximately 50 GB of expert data alone
  5) Keep the current model, or choose a model later
These are large downloads. The exact Strata plan is shown before download.
MODEL_MENU
        while :; do
            ask 'Model choice' 1
            choice=$STATION_ANSWER
            case "$choice" in
                1) STATION_MODEL=iq2_xs; break ;;
                2) STATION_MODEL=q2_0; break ;;
                3) STATION_MODEL=iq3_xxs; break ;;
                4) STATION_MODEL=iq3_s; break ;;
                5) return 0 ;;
            esac
        done
    fi
    if [[ -n ${STATION_CONFIG[STRATA_CONTEXT]:-} ]]; then
        STATION_CONTEXT=${STATION_CONFIG[STRATA_CONTEXT]}
    elif [[ $STATION_NON_INTERACTIVE == 0 && ${STATION_CONFIG[INSTALL_MODEL]:-} != true ]]; then
        while :; do
            ask 'Context size: 8k, 16k, or 32k' "$STATION_CONTEXT"
            case "$STATION_ANSWER" in 8k|16k|32k) STATION_CONTEXT=$STATION_ANSWER; break ;; esac
        done
    fi
    local -a launch_args=(--backend amd --family qwen --model "$STATION_MODEL"
        --context "$STATION_CONTEXT" --parallel 1 --vision off --access local --port "$STATION_PORT"
        --api-key-env STRATA_API_KEY --data-dir "$STATION_HOME/models" --save-preset station
        --feed "$STRATA_RELEASE_FEED")
    as_strata "$STATION_CLI" launch "${launch_args[@]}" --plan
    if [[ ${STATION_CONFIG[INSTALL_MODEL]:-} != true ]]; then
        if ! ask_yes 'Download/prepare this model and replace any currently serving model?' y; then return 0; fi
    fi
    save_settings
    stop_tunnel
    systemctl disable --now strata.service
    # A previous interrupted provisioning run may have left a managed launch.
    as_strata "$STATION_CLI" launch --stop --preset station >/dev/null 2>&1 || true
    say 'Preparing model files. Large downloads can take a long time; leave this terminal open.'
    if ! as_strata "$STATION_CLI" launch "${launch_args[@]}" --yes --no-tui; then
        as_strata "$STATION_CLI" launch --stop --preset station >/dev/null 2>&1 || true
        die 'Model preparation failed. Files are retained so you can retry sudo strata-station model.'
    fi
    if ! api_check wait || ! api_check local; then
        as_strata "$STATION_CLI" launch --stop --preset station >/dev/null 2>&1 || true
        die 'Prepared model did not pass inference/authentication. The tunnel remains stopped.'
    fi
    as_strata "$STATION_CLI" launch --stop --preset station
    [[ -f "$STATION_PROFILE" ]] || die 'The expected launch-station profile was not created.'
    systemctl reset-failed strata.service || true
    systemctl start strata.service
    if ! api_check wait || ! api_check local; then
        systemctl stop strata.service
        die 'Foreground boot service did not pass verification. Inspect journalctl -u strata.service.'
    fi
    systemctl enable strata.service
    start_tunnel_if_ready
    say 'Model is ready, with automatic startup after reboot.'
}
configure_tunnel() {
    STATION_PHASE='Cloudflare named tunnel configuration'
    command -v cloudflared >/dev/null || die 'Run the installer first.'
    local choice cf_token='' root_profile_dir cert_path existing_id credential_id
    local previous_cf_mode=$STATION_CF_MODE previous_cf_id=$STATION_CF_ID
    case "${STATION_CONFIG[CLOUDFLARE_MODE]:-}" in
        local) choice=1 ;;
        remote) choice=2 ;;
        skip) say 'Tunnel configuration skipped; an existing tunnel is preserved.'; return 0 ;;
        *)
            cat >&3 <<'TUNNEL_MENU'
Cloudflare named tunnel:
  1) Create/reuse this installer's locally managed named tunnel (browser login on Mac)
  2) Use an existing remotely managed tunnel connector token
  3) Keep the existing configuration / configure later
A public hostname under a domain in your Cloudflare account is required.
MODEL NOTE: the tunnel starts only after local authenticated inference passes.
TUNNEL_MENU
            while :; do
                ask 'Tunnel choice' 1
                choice=$STATION_ANSWER
                case "$choice" in 1|2|3) break ;; esac
            done ;;
    esac
    [[ "$choice" != 3 ]] || return 0
    if [[ -n ${STATION_CONFIG[CLOUDFLARE_HOSTNAME]:-} ]]; then
        STATION_CF_HOST=${STATION_CONFIG[CLOUDFLARE_HOSTNAME]}
    elif [[ $STATION_NON_INTERACTIVE == 0 && -z ${STATION_CONFIG[CLOUDFLARE_MODE]:-} || -z "$STATION_CF_HOST" ]]; then
        while :; do
            ask 'Public hostname, for example strata.your-domain.com' "$STATION_CF_HOST"
            STATION_ANSWER=${STATION_ANSWER,,}
            if valid_hostname "$STATION_ANSWER"; then STATION_CF_HOST=$STATION_ANSWER; break; fi
            warn 'Enter a hostname only, without https://, a port, a path, or wildcard.'
        done
    fi
    stop_tunnel
    if [[ "$choice" == 1 ]]; then
        STATION_CF_MODE=local
        if [[ -n ${STATION_CONFIG[CLOUDFLARE_TUNNEL_NAME]:-} ]]; then
            STATION_ANSWER=${STATION_CONFIG[CLOUDFLARE_TUNNEL_NAME]}
        elif [[ -n ${STATION_CONFIG[CLOUDFLARE_MODE]:-} || $STATION_NON_INTERACTIVE == 1 ]]; then
            STATION_ANSWER=${STATION_CF_NAME:-strata-${STATION_CF_HOST//./-}}
        else
            ask 'Tunnel name' "${STATION_CF_NAME:-strata-${STATION_CF_HOST//./-}}"
        fi
        [[ "$STATION_ANSWER" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$ ]] || die 'Use letters, digits, hyphens or underscores for the tunnel name.'
        STATION_CF_NAME=$STATION_ANSWER
        cert_path="$STATION_DIR/cloudflare-cert.pem"
        if [[ ! -s "$cert_path" ]]; then
            root_profile_dir=$(getent passwd root | cut -d: -f6)
            if [[ ! -s "$root_profile_dir/.cloudflared/cert.pem" ]]; then
                say 'Open the Cloudflare authorization URL printed below on your Mac. Keep this command running.'
                runuser -u root -- cloudflared tunnel login
            fi
            [[ -s "$root_profile_dir/.cloudflared/cert.pem" ]] || die 'Cloudflare browser authorization did not produce the account certificate.'
            install -m 0600 "$root_profile_dir/.cloudflared/cert.pem" "$cert_path"
        fi
        existing_id=$(cloudflared tunnel --origincert "$cert_path" list --name "$STATION_CF_NAME" --output json |
            python3 -c 'import json,sys; matches=[x["id"] for x in (json.load(sys.stdin) or []) if x.get("name")==sys.argv[1]]; assert len(matches)<=1, "Ambiguous tunnel name"; print(matches[0] if matches else "")' "$STATION_CF_NAME")
        if [[ -n "$existing_id" ]]; then
            credential_id=''
            if [[ -s "$STATION_DIR/tunnel.json" && $(stat -c '%u' "$STATION_DIR/tunnel.json") == 0 ]]; then
                credential_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("TunnelID", ""))' "$STATION_DIR/tunnel.json")
            fi
            if [[ ( "$previous_cf_mode" != local || "$previous_cf_id" != "$existing_id" ) && "$credential_id" != "$existing_id" ]]; then
                die 'That name belongs to a tunnel not recorded by this installer. Choose a new dedicated name, or use option 2 for an existing tunnel.'
            fi
            STATION_CF_ID=$existing_id
            if [[ "$credential_id" != "$STATION_CF_ID" ]]; then
                cloudflared tunnel --origincert "$cert_path" token --cred-file "$STATION_WORK/tunnel.json" "$STATION_CF_ID"
                install -m 0600 "$STATION_WORK/tunnel.json" "$STATION_DIR/tunnel.json"
            fi
        else
            cloudflared tunnel --origincert "$cert_path" create --credentials-file "$STATION_WORK/tunnel.json" \
                --output json "$STATION_CF_NAME" > "$STATION_WORK/tunnel-create.json"
            install -m 0600 "$STATION_WORK/tunnel.json" "$STATION_DIR/tunnel.json"
            STATION_CF_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["TunnelID"])' "$STATION_DIR/tunnel.json")
        fi
        [[ "$STATION_CF_ID" =~ ^[a-fA-F0-9-]{36}$ ]] || die 'Cloudflare returned an invalid tunnel UUID.'
        # Record ownership before DNS, so a DNS error can be retried safely.
        save_settings
        # No --overwrite-dns: unrelated DNS records are never replaced automatically.
        cloudflared tunnel --origincert "$cert_path" route dns "$STATION_CF_ID" "$STATION_CF_HOST"
        cat > "$STATION_DIR/cloudflared.yml" <<CF_CONFIG
tunnel: $STATION_CF_ID
ingress:
  - hostname: $STATION_CF_HOST
    service: http://127.0.0.1:$STATION_PORT
  - service: http_status:404
CF_CONFIG
        chmod 0600 "$STATION_DIR/cloudflared.yml"
        cloudflared tunnel --config "$STATION_DIR/cloudflared.yml" ingress validate
        cat > "$STATION_WORK/tunnel-service-lines" <<CF_LOCAL_LINES
LoadCredential=cloudflared.yml:$STATION_DIR/cloudflared.yml
LoadCredential=tunnel.json:$STATION_DIR/tunnel.json
ExecStart=/usr/bin/cloudflared tunnel --config %d/cloudflared.yml --no-autoupdate --metrics 127.0.0.1:$STATION_METRICS_PORT --loglevel info run --credentials-file %d/tunnel.json $STATION_CF_ID
CF_LOCAL_LINES
    else
        STATION_CF_MODE=remote
        say "In Cloudflare, the tunnel's published application must map $STATION_CF_HOST to http://127.0.0.1:$STATION_PORT"
        if [[ -n ${STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]:-} ]]; then
            cf_token=${STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]}
        elif [[ "$previous_cf_mode" == remote && -s "$STATION_DIR/cloudflare-token" ]]; then
            cf_token=$(< "$STATION_DIR/cloudflare-token")
            say 'Reusing the installed tunnel connector token.'
        else
            (( STATION_NON_INTERACTIVE == 0 )) || die 'Set CLOUDFLARE_TUNNEL_TOKEN for this tunnel.'
            printf 'Paste ONLY the tunnel connector token (hidden; not an account API token): ' >&3
            IFS= read -r -s cf_token <&3 || die 'Token input ended.'
            printf '\n' >&3
        fi
        if ! printf '%s' "$cf_token" | valid_connector_token; then
            unset cf_token
            die 'This is not a valid tunnel connector token. An account API token cannot be used here.'
        fi
        printf '%s\n' "$cf_token" > "$STATION_DIR/cloudflare-token"
        chmod 0600 "$STATION_DIR/cloudflare-token"
        unset cf_token
        unset 'STATION_CONFIG[CLOUDFLARE_TUNNEL_TOKEN]'
        cat > "$STATION_WORK/tunnel-service-lines" <<CF_REMOTE_LINES
LoadCredential=tunnel-token:$STATION_DIR/cloudflare-token
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:$STATION_METRICS_PORT --loglevel info run --token-file %d/tunnel-token
CF_REMOTE_LINES
    fi
    {
        cat <<'CF_UNIT_TOP'
[Unit]
Description=Named Cloudflare Tunnel for Strata
Wants=network-online.target
After=network-online.target strata.service
StartLimitIntervalSec=600
StartLimitBurst=10

[Service]
Type=notify
DynamicUser=yes
CF_UNIT_TOP
        cat "$STATION_WORK/tunnel-service-lines"
        cat <<'CF_UNIT_BOTTOM'
Restart=on-failure
RestartSec=10
TimeoutStartSec=90
TimeoutStopSec=30
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
UMask=0077

[Install]
WantedBy=multi-user.target
CF_UNIT_BOTTOM
    } > /etc/systemd/system/cloudflared-strata.service
    chmod 0644 /etc/systemd/system/cloudflared-strata.service
    save_settings
    systemctl daemon-reload
    start_tunnel_if_ready
    say "Named tunnel configured for https://$STATION_CF_HOST"
}
show_key() {
    [[ -r "$STATION_API_ENV" ]] || die 'The API key does not exist; run installation first.'
    local key_line
    IFS= read -r key_line < "$STATION_API_ENV"
    printf '%s\n' "${key_line#STRATA_API_KEY=}"
}
show_status() {
    systemctl --no-pager --full status ssh.socket ssh.service strata.service cloudflared-strata.service || true
    printf '\nStrata API key: sudo strata-station key\n'
    printf 'Logs: sudo journalctl -u strata.service -u cloudflared-strata.service -n 100 --no-pager\n'
}
check_all() {
    local failed=0
    gpu_check || failed=1
    if [[ -f "$STATION_PROFILE" ]]; then
        api_check local || failed=1
    else
        warn 'No model has been configured. Run sudo strata-station model.'
        failed=1
    fi
    if [[ -n "$STATION_CF_HOST" ]]; then
        api_check remote "https://$STATION_CF_HOST" || failed=1
    else
        warn 'No public tunnel hostname configured. Local SSH forwarding remains available.'
    fi
    if [[ -e /var/run/reboot-required ]]; then warn 'Ubuntu reports that a reboot is required.'; fi
    return "$failed"
}
summary() {
    say 'Installation stages completed'
    printf 'SSH account: %s\n' "$STATION_LOGIN"
    printf 'Server addresses: '
    hostname -I
    printf 'Local Strata origin: http://127.0.0.1:%s\n' "$STATION_PORT"
    [[ -z "$STATION_CF_HOST" ]] || printf 'Public API base: https://%s/v1\n' "$STATION_CF_HOST"
    printf '\nNext commands:\n  sudo strata-station status\n  sudo strata-station key\n  sudo strata-station check\n'
    [[ -f "$STATION_PROFILE" ]] || printf '  sudo strata-station model    # needed before inference is available\n'
    [[ -n "$STATION_CF_MODE" ]] || printf '  sudo strata-station tunnel   # needed for the public hostname\n'
    if [[ -e /var/run/reboot-required ]]; then
        warn 'Reboot when ready: sudo reboot. Then run sudo strata-station check from your Mac.'
    fi
    printf '\nThe API key also permits Strata management. Keep it private.\n'
    printf 'GPU clocks and power limits remain under the normal driver controls; actual speed must be benchmarked.\n'
}
main() {
    local action=install action_set=0 env_file='' env_explicit=0 script_path
    while (( $# )); do
        case "$1" in
            -h|--help|help)
                sed -n '2,/^set +x/{ /^set +x/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
                return 0 ;;
            --env-file)
                (( $# >= 2 )) && [[ -n "$2" ]] || die '--env-file needs a file path.'
                (( env_explicit == 0 )) || die 'Use --env-file only once.'
                env_file=$2; env_explicit=1; shift 2 ;;
            --non-interactive) STATION_NON_INTERACTIVE=1; shift ;;
            install|model|tunnel|check|status|key)
                (( action_set == 0 )) || die 'Choose only one operation.'
                action=$1; action_set=1; shift ;;
            *) die 'Usage: strata-station [install|model|tunnel|check|status|key] [--env-file PATH] [--non-interactive]' ;;
        esac
    done
    if [[ "$action" == check || "$action" == status || "$action" == key ]]; then
        (( env_explicit == 0 )) || die '--env-file is used with install, model, or tunnel only.'
    fi
    require_host
    trap 'on_error "$?" "$LINENO"' ERR
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$action" == install || "$action" == model || "$action" == tunnel ]]; then
        exec 9>/run/lock/strata-station.lock
        flock -n 9 || die 'Another station setup/model/tunnel operation is running.'
    fi
    STATION_WORK=$(mktemp -d /var/tmp/strata-station.XXXXXXXX)
    load_settings
    command -v python3 >/dev/null || die 'Python 3 is required; install it with sudo apt-get install python3 and retry.'
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ $env_explicit == 0 && "$action" == install && "$script_path" != /usr/local/sbin/strata-station ]]; then
        if [[ -e "${script_path%/*}/.env" || -L "${script_path%/*}/.env" ]]; then
            env_file="${script_path%/*}/.env"
        fi
    fi
    if [[ -n "$env_file" ]]; then load_dotenv "$env_file"; fi
    STATION_PHASE='Configuration validation'
    validate_config "$action"
    if [[ "$action" == install || "$action" == model || "$action" == tunnel ]]; then
        if (( STATION_NON_INTERACTIVE == 1 )); then
            exec 3>&2
        else
            exec 3<>/dev/tty || die 'Run in a terminal, or provide complete .env settings and use --non-interactive.'
        fi
    fi
    install -d -m 0755 "$STATION_DIR"
    case "$action" in
        install)
            say 'Ubuntu 26.04 inference station: stock AMD driver, native Strata, named tunnel'
            install_packages
            configure_login
            configure_ssh
            configure_service_account
            install_cloudflared
            # Keep one complete copy so deferred setup and checks work after reboot.
            if [[ $(readlink -f "${BASH_SOURCE[0]}") != /usr/local/sbin/strata-station ]]; then
                install -m 0755 "${BASH_SOURCE[0]}" /usr/local/sbin/strata-station
            fi
            write_station_service
            install_strata
            if gpu_check; then STATION_GPU_OK=1; else STATION_GPU_OK=0; fi
            configure_tunnel
            if (( STATION_GPU_OK == 1 )); then
                case "${STATION_CONFIG[INSTALL_MODEL]:-}" in
                    true) configure_model ;;
                    false) say 'Model preparation skipped by INSTALL_MODEL=false.' ;;
                    *) if ask_yes 'Select and download a model now?' y; then configure_model; fi ;;
                esac
            else
                warn 'Model setup deferred until GPU verification passes. Reboot if firmware/kernel updates require it.'
            fi
            if (( STATION_GPU_OK == 1 )) && [[ -f "$STATION_PROFILE" ]]; then
                # Resume a preserved model even when a rerun's model prompt was skipped.
                systemctl reset-failed strata.service || true
                systemctl start strata.service
                api_check wait
                api_check local
                systemctl enable strata.service
                start_tunnel_if_ready
            fi
            summary ;;
        model) configure_model ;;
        tunnel) configure_tunnel ;;
        check) check_all ;;
        status) show_status ;;
        key) show_key ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
