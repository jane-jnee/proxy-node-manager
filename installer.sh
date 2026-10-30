#!/usr/bin/env bash
# Self-contained customized installer. Upload this ONE file to your own host.
set -u
umask 077
manager_temp=$(mktemp -d "${TMPDIR:-/tmp}/proxy-manager.XXXXXXXX") || exit 1
cleanup_manager_temp() {
    rm -f -- "$manager_temp/proxy-node-manager.sh"
    rmdir -- "$manager_temp" 2>/dev/null || true
}
trap cleanup_manager_temp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$manager_temp/proxy-node-manager.sh" <<'PROXY_MANAGER_EMBEDDED_V221_6a559016113994e6b289690b'
#!/usr/bin/env bash
# Customized from dabadabader/install: advertising removed; independent nodes.
# Run on your own Linux server. Sourcing this file performs no installation.

MANAGER_VERSION='2.2.1'
WORK_DIR="${PROXY_WORK_DIR:-/etc/sing-box}"
CONFIG_FILE="${WORK_DIR}/config.json"
STATE_DIR="${WORK_DIR}/node-manager"
META_FILE="${STATE_DIR}/nodes.json"
BACKUP_DIR="${STATE_DIR}/backups"
SB_BIN="${PROXY_SB_BIN:-${WORK_DIR}/sing-box}"
DEFAULT_SB_VERSION='1.14.4'
DEFAULT_SNI='addons.mozilla.org'
MANAGER_PATH="${PROXY_MANAGER_PATH:-/usr/local/lib/proxy-node-manager/manager.sh}"
SHORTCUT_PATH="${PROXY_SHORTCUT_PATH:-/usr/local/bin/menu}"
LOCK_HELD=0

ok() { printf '%s\n' "$*" >&2; }
warn() { printf '提示：%s\n' "$*" >&2; }
err() { printf '错误：%s\n' "$*" >&2; }
prompt_read() {
    local prompt="$1" destination="$2"
    if [[ -r /dev/tty ]]; then
        IFS= read -r -p "$prompt" "$destination" </dev/tty
    else
        IFS= read -r -p "$prompt" "$destination"
    fi
}

prepare_workspace() {
    umask 077
    mkdir -p -- "$WORK_DIR" "$STATE_DIR" "$BACKUP_DIR" || return 1
    chmod 700 -- "$STATE_DIR" "$BACKUP_DIR" || return 1
    if [[ ! -e "$META_FILE" ]]; then
        printf '{"nodes":{}}\n' > "$META_FILE" || return 1
    fi
    jq -e 'type == "object" and (.nodes | type == "object")' "$META_FILE" >/dev/null || {
        err "节点名称记录无效，保留原文件：$META_FILE"; return 1;
    }
}

acquire_lock() {
    [[ "$LOCK_HELD" == 1 ]] && return 0
    prepare_workspace || return 1
    command -v flock >/dev/null || { err '缺少 flock，请先安装依赖。'; return 1; }
    exec 9>"$STATE_DIR/manager.lock" || return 1
    # Foreground operations wait out the quota daemon's short snapshots.
    # The daemon keeps its separate nonblocking lock and skips busy ticks.
    flock -w 15 9 || { err '等待配置锁超时（15 秒）；其他操作仍在修改配置，请稍后重试。'; return 1; }
    LOCK_HELD=1
}

read_current_config() {
    if [[ -e "$CONFIG_FILE" ]]; then
        jq -e 'if type == "object" and ((.inbounds // []) | type == "array") then . else error("invalid config") end' "$CONFIG_FILE"
        return
    fi
    local fragments=()
    shopt -s nullglob
    fragments=("$WORK_DIR"/conf/*.json)
    shopt -u nullglob
    if ((${#fragments[@]})); then
        err '发现旧配置分片，但 config.json 不存在。请先恢复完整配置；本工具不会猜测合并或删除旧分片。'
        return 1
    fi
    printf '%s\n' '{"log":{"level":"info"},"outbounds":[{"type":"direct","tag":"direct"}],"inbounds":[]}'
}

read_metadata() {
    if [[ -e "$META_FILE" ]]; then jq -e . "$META_FILE"; else printf '{"nodes":{}}\n'; fi
}

random_hex() { openssl rand -hex "${1:-8}"; }
new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local r; r=$(random_hex 16) || return 1
        printf '%s-%s-4%s-a%s-%s\n' "${r:0:8}" "${r:8:4}" "${r:13:3}" "${r:17:3}" "${r:20:12}"
    fi
}

valid_port() { [[ "$1" =~ ^[1-9][0-9]{3,4}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
valid_server() {
    # Defined in the link module; use identical validation before committing.
    _links_server "$1" >/dev/null 2>&1
}
valid_sni() { _links_valid_hostname "$1" && [[ ! "$1" =~ ^[0-9.]+$ ]]; }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

port_in_use() {
    local port="$1" ignore_tag="${2:-}" config
    config=$(read_current_config) || return 0
    if jq -e --argjson p "$port" --arg tag "$ignore_tag" \
        'any(.inbounds[]?; .listen_port == $p and (($tag == "") or .tag != $tag))' <<<"$config" >/dev/null; then
        return 0
    fi
    if command -v ss >/dev/null; then
        # Test both TCP/UDP listeners, not a substring such as 1080 matching 11080.
        ss -H -lntu 2>/dev/null | awk -v p="$port" '{n=split($5,a,":"); if(a[n]==p) found=1} END {exit !found}' && return 0
    fi
    return 1
}

find_free_port() {
    local port="${1:-$((RANDOM + 10000))}" attempts=0
    while ((attempts < 64512)); do
        if valid_port "$port" && ! port_in_use "$port"; then printf '%s\n' "$port"; return 0; fi
        port=$((port + 1)); ((port > 65535)) && port=1024
        attempts=$((attempts + 1))
    done
    err '未找到空闲端口。'; return 1
}

validate_config() {
    local candidate="$1"
    jq -e 'type == "object" and ((.inbounds // []) | type == "array")' "$candidate" >/dev/null || return 1
    [[ -x "$SB_BIN" ]] || { err "缺少 sing-box 主程序：$SB_BIN"; return 1; }
    (cd "$WORK_DIR" && "$SB_BIN" check -c "$candidate")
}

restore_transaction() {
    local backup="$1" had_config="$2" config_temp='' meta_temp
    meta_temp=$(mktemp "$STATE_DIR/restore-meta.XXXXXX") || return 1
    if ! cp -p -- "$backup/nodes.json" "$meta_temp"; then rm -f -- "$meta_temp"; return 1; fi
    if ((had_config)); then
        config_temp=$(mktemp "$WORK_DIR/.restore-config.XXXXXX") || { rm -f -- "$meta_temp"; return 1; }
        if ! cp -p -- "$backup/config.json" "$config_temp"; then rm -f -- "$meta_temp" "$config_temp"; return 1; fi
        if ! mv -f -- "$config_temp" "$CONFIG_FILE"; then rm -f -- "$meta_temp" "$config_temp"; return 1; fi
    elif ! rm -f -- "$CONFIG_FILE"; then
        rm -f -- "$meta_temp"; return 1
    fi
    if ! mv -f -- "$meta_temp" "$META_FILE"; then rm -f -- "$meta_temp"; return 1; fi
}

recover_candidate() {
    local backup="$1" had_config="$2"
    if ! restore_transaction "$backup" "$had_config"; then
        svc_stop || true
        err "无法完整恢复配置，已尝试停止服务；请从备份恢复：$backup"
        return 1
    fi
    if quota_enabled && ! quota_sync; then
        svc_stop || true
        err "原配置已恢复，但流量规则恢复失败，已尝试停止代理；备份：$backup"
        return 1
    fi
    if ((had_config)); then
        svc_restart || { warn "原配置已恢复，但服务未启动；备份：$backup"; return 1; }
    else
        svc_stop || true
    fi
}

apply_candidate() {
    local candidate="$1" meta_candidate="$2" backup had_config=0
    prepare_workspace || return 1
    jq -e 'type == "object" and (.nodes | type == "object")' "$meta_candidate" >/dev/null || return 1
    validate_config "$candidate" || { err '候选配置校验失败，原配置未改动。'; return 1; }
    if quota_enabled; then
        quota_service_ready && quota_snapshot || { err '流量服务未就绪，原配置未改动。'; return 1; }
    fi
    backup=$(mktemp -d "$BACKUP_DIR/transaction-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
    if [[ -e "$CONFIG_FILE" ]]; then
        cp -p -- "$CONFIG_FILE" "$backup/config.json" || return 1
        had_config=1
    fi
    cp -p -- "$META_FILE" "$backup/nodes.json" || return 1
    chmod 600 -- "$candidate" "$meta_candidate" || return 1
    # Do not leave the old listener serving on a port whose quota rules changed.
    if quota_enabled; then
        svc_stop || return 1
        local kernel
        if ! kernel=$(quota_read_kernel) || ! quota_guard "$kernel" || ! quota_snapshot; then
            recover_candidate "$backup" "$had_config" || true
            return 1
        fi
    fi
    if ! mv -f -- "$candidate" "$CONFIG_FILE" || ! mv -f -- "$meta_candidate" "$META_FILE"; then
        recover_candidate "$backup" "$had_config" || true
        return 1
    fi
    if quota_sync && svc_restart; then
        ok "配置已生效。回滚备份：$backup"
        return 0
    fi
    err '配置或流量规则未成功生效，正在恢复本次修改前的配置。'
    recover_candidate "$backup" "$had_config" || true
    return 1
}

build_inbound() {
    local protocol="$1" tag="$2" port="$3" credential="$4" sni="${5:-}" private="${6:-}" shortid="${7:-}"
    valid_port "$port" || { err '端口应在 1024–65535。'; return 1; }
    case "$protocol" in
        vless)
            valid_uuid "$credential" && valid_sni "$sni" && [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ && "$shortid" =~ ^[0-9a-fA-F]{16}$ ]] || {
                err 'VLESS UUID、SNI 或 Reality 密钥参数无效。'; return 1;
            }
            jq -cn --arg tag "$tag" --argjson port "$port" --arg uuid "$credential" --arg sni "$sni" --arg private "$private" --arg sid "$shortid" \
              '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private,short_id:[$sid]}}}'
            ;;
        vmess)
            valid_uuid "$credential" || { err 'VMess UUID 无效。'; return 1; }
            jq -cn --arg tag "$tag" --argjson port "$port" --arg uuid "$credential" \
              '{type:"vmess",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid}],transport:{type:"ws",path:("/"+$uuid+"-vmess")}}'
            ;;
        shadowsocks)
            [[ ${#credential} -ge 12 ]] || { err 'Shadowsocks 密码至少 12 位。'; return 1; }
            jq -cn --arg tag "$tag" --argjson port "$port" --arg password "$credential" \
              '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:"aes-128-gcm",password:$password}'
            ;;
        *) err '不支持的节点协议。'; return 1 ;;
    esac
}

add_node_data() (
    local protocol="$1" name="$2" server="$3" port="$4" credential="$5" sni="${6:-}" private="${7:-}" public="${8:-}" shortid="${9:-}" quota_bytes="${10:-0}"
    local config metadata tag inbound candidate meta_candidate
    acquire_lock || return 1
    quota_valid_bytes "$quota_bytes" || { err '无效的节点流量额度。'; return 1; }
    if ((quota_bytes > 0)); then
        quota_enabled && quota_service_ready || { err '需要先启用流量服务。'; return 1; }
    fi
    valid_server "$server" || { err '节点服务器地址格式不正确。'; return 1; }
    [[ -n "$name" && ${#name} -le 80 && "$name" != *$'\n'* && "$name" != *$'\r'* ]] || { err '节点名称应为 1–80 个字符。'; return 1; }
    valid_port "$port" || { err '端口应在 1024–65535。'; return 1; }
    port_in_use "$port" && { err "端口 $port 已被配置或占用，请另选端口。"; return 1; }
    config=$(read_current_config) || return 1
    metadata=$(read_metadata) || return 1
    tag="pnm-${protocol}-$(random_hex 8)" || return 1
    if jq -e --arg tag "$tag" 'any(.inbounds[]?; .tag == $tag)' <<<"$config" >/dev/null; then
        err '节点 ID 冲突，请重试。'; return 1
    fi
    inbound=$(build_inbound "$protocol" "$tag" "$port" "$credential" "$sni" "$private" "$shortid") || return 1
    if [[ "$protocol" == vless && ! "$public" =~ ^[A-Za-z0-9_-]{43}$ ]]; then err 'Reality 公钥格式无效。'; return 1; fi
    candidate=$(mktemp "$STATE_DIR/config.XXXXXX") || return 1
    meta_candidate=$(mktemp "$STATE_DIR/meta.XXXXXX") || { rm -f -- "$candidate"; return 1; }
    if ! jq --argjson inbound "$inbound" '.inbounds = ((.inbounds // []) + [$inbound])' <<<"$config" > "$candidate" ||
       ! jq --arg tag "$tag" --arg name "$name" --arg server "$server" --arg public "$public" --argjson quota "$quota_bytes" --arg created "$(date -u +%FT%TZ)" \
            '.nodes[$tag] = {name:$name,server:$server,public_key:$public,created_at:$created,quota_bytes:$quota}' <<<"$metadata" > "$meta_candidate"; then
        rm -f -- "$candidate" "$meta_candidate"; return 1
    fi
    if apply_candidate "$candidate" "$meta_candidate"; then printf '%s\n' "$tag"; return 0; fi
    rm -f -- "$candidate" "$meta_candidate"; return 1
)

require_managed_node() {
    local tag="$1" config metadata
    config=$(read_current_config) || return 1
    metadata=$(read_metadata) || return 1
    jq -e --arg tag "$tag" '.nodes[$tag] != null' <<<"$metadata" >/dev/null &&
      jq -e --arg tag "$tag" '([.inbounds[]? | select(.tag == $tag)] | length) == 1' <<<"$config" >/dev/null || {
        err '此节点不属于本工具创建的节点，保留原设置；旧节点可查看和导出。'; return 1;
    }
}

update_node_port() (
    local tag="$1" port="$2" candidate meta_candidate config current_port
    acquire_lock && require_managed_node "$tag" || return 1
    valid_port "$port" || { err '端口应在 1024–65535。'; return 1; }
    config=$(read_current_config) || return 1
    current_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .listen_port' <<<"$config")
    [[ "$current_port" == "$port" ]] && { ok '端口未变化。'; return 0; }
    port_in_use "$port" && { err "端口 $port 已被配置或占用。"; return 1; }
    candidate=$(mktemp "$STATE_DIR/config.XXXXXX") || return 1
    meta_candidate=$(mktemp "$STATE_DIR/meta.XXXXXX") || { rm -f -- "$candidate"; return 1; }
    jq --arg tag "$tag" --argjson port "$port" '(.inbounds[] | select(.tag == $tag) | .listen_port) = $port' <<<"$config" > "$candidate" &&
       cp -- "$META_FILE" "$meta_candidate" && apply_candidate "$candidate" "$meta_candidate"
    local result=$?; rm -f -- "$candidate" "$meta_candidate"; return "$result"
)

rotate_node_credential() (
    local tag="$1" credential="$2" candidate meta_candidate config protocol
    acquire_lock && require_managed_node "$tag" || return 1
    config=$(read_current_config) || return 1
    protocol=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .type' <<<"$config")
    case "$protocol" in
        vless|vmess) valid_uuid "$credential" || { err 'UUID 格式不正确。'; return 1; } ;;
        shadowsocks) [[ ${#credential} -ge 12 ]] || { err '密码至少 12 位。'; return 1; } ;;
        *) err '此协议不支持修改凭据。'; return 1 ;;
    esac
    candidate=$(mktemp "$STATE_DIR/config.XXXXXX") || return 1
    meta_candidate=$(mktemp "$STATE_DIR/meta.XXXXXX") || { rm -f -- "$candidate"; return 1; }
    if [[ "$protocol" == shadowsocks ]]; then
        jq --arg tag "$tag" --arg credential "$credential" '(.inbounds[] | select(.tag == $tag) | .password) = $credential' <<<"$config" > "$candidate"
    else
        jq --arg tag "$tag" --arg credential "$credential" '(.inbounds[] | select(.tag == $tag) | .users[0].uuid) = $credential' <<<"$config" > "$candidate"
    fi
    local result=$?
    if ((result == 0)); then cp -- "$META_FILE" "$meta_candidate" && apply_candidate "$candidate" "$meta_candidate"; result=$?; fi
    rm -f -- "$candidate" "$meta_candidate"; return "$result"
)

delete_node_data() (
    local tag="$1" candidate meta_candidate config metadata
    acquire_lock && require_managed_node "$tag" || return 1
    config=$(read_current_config) && metadata=$(read_metadata) || return 1
    candidate=$(mktemp "$STATE_DIR/config.XXXXXX") || return 1
    meta_candidate=$(mktemp "$STATE_DIR/meta.XXXXXX") || { rm -f -- "$candidate"; return 1; }
    jq --arg tag "$tag" '.inbounds = [.inbounds[]? | select(.tag != $tag)]' <<<"$config" > "$candidate" &&
       jq --arg tag "$tag" 'del(.nodes[$tag])' <<<"$metadata" > "$meta_candidate" &&
       apply_candidate "$candidate" "$meta_candidate"
    local result=$?; rm -f -- "$candidate" "$meta_candidate"; return "$result"
)

list_nodes() {
    local config metadata
    config=$(read_current_config) && metadata=$(read_metadata) || return 1
    printf '编号\t名称\t协议\t端口\t来源\n'
    jq -r --argjson meta "$metadata" '(.inbounds // []) | to_entries[] | .key as $i | .value as $n |
      [($i+1),($meta.nodes[$n.tag // ""].name // $n.tag // "无名称"),$n.type,($n.listen_port // "—"),
      (if $meta.nodes[$n.tag // ""] != null then "本工具" else "原有配置/只读" end)] | @tsv' <<<"$config"
}

choose_node() {
    local index config tag
    list_nodes || return 1
    prompt_read '输入节点编号（回车取消）：' index || return 1
    [[ -n "$index" ]] || return 1
    [[ "$index" =~ ^[1-9][0-9]*$ ]] || { err '节点编号无效。'; return 1; }
    config=$(read_current_config) || return 1
    tag=$(jq -r --argjson i "$((10#$index-1))" '.inbounds[$i].tag // empty' <<<"$config")
    [[ -n "$tag" ]] || { err '节点不存在或缺少 tag。'; return 1; }
    SELECTED_TAG="$tag"
}
# Official downloads, dependency installation and service control.
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; }
get_latest_version() {
    local version response
    if [[ -n "${PROXY_SINGBOX_VERSION:-}" ]]; then
        version="${PROXY_SINGBOX_VERSION#v}"
    elif response=$(curl -fsSL --retry 2 --connect-timeout 10 --max-time 45 \
            'https://api.github.com/repos/SagerNet/sing-box/releases/latest'); then
        version=$(jq -er '.tag_name | select(type == "string") | ltrimstr("v")' <<<"$response") || version=''
    else
        version=''
    fi
    if [[ -n "${PROXY_SINGBOX_VERSION:-}" ]] && ! valid_version "$version"; then
        err '指定的 sing-box 版本格式无效。'; return 1
    fi
    if ! valid_version "$version"; then
        warn "无法从官方 API 获取有效稳定版本，使用预设版本 $DEFAULT_SB_VERSION。"
        version="$DEFAULT_SB_VERSION"
    fi
    valid_version "$version" || return 1
    printf '%s\n' "$version"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) SB_ARCH=amd64 ;;
        aarch64|arm64) SB_ARCH=arm64 ;;
        armv7l) SB_ARCH=armv7 ;;
        *) err "暂不支持的架构：$(uname -m)"; return 1 ;;
    esac
}

ensure_dependencies() {
    local missing=0 command_name
    for command_name in curl jq tar openssl ss flock sha256sum base64; do
        command -v "$command_name" >/dev/null || missing=1
    done
    ((missing == 0)) && return 0
    ok '安装本工具所需的系统依赖。'
    if command -v apt-get >/dev/null; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates curl jq tar openssl iproute2 util-linux coreutils || return 1
    elif command -v dnf >/dev/null; then
        dnf install -y ca-certificates curl jq tar openssl iproute util-linux coreutils || return 1
    elif command -v yum >/dev/null; then
        yum install -y ca-certificates curl jq tar openssl iproute util-linux coreutils || return 1
    elif command -v apk >/dev/null; then
        apk add --no-cache ca-certificates curl jq tar openssl iproute2 util-linux coreutils || return 1
    elif command -v pacman >/dev/null; then
        pacman -S --needed --noconfirm ca-certificates curl jq tar openssl iproute2 util-linux coreutils || return 1
    else
        err '请先手动安装 curl jq tar openssl iproute2 util-linux coreutils。'; return 1
    fi
    for command_name in curl jq tar openssl ss flock sha256sum base64; do
        command -v "$command_name" >/dev/null || { err "依赖仍缺失：$command_name"; return 1; }
    done
}

ensure_singbox() {
    [[ -x "$SB_BIN" ]] && return 0
    prepare_workspace && detect_arch || return 1
    local version stage archive asset url metadata digest binary
    version=$(get_latest_version) || return 1
    stage=$(mktemp -d "$STATE_DIR/download.XXXXXX") || return 1
    asset="sing-box-${version}-linux-${SB_ARCH}.tar.gz"
    archive="$stage/archive.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${asset}"
    ok "下载官方 sing-box v${version} (${SB_ARCH}) ..."
    if ! curl -fL --retry 2 --connect-timeout 15 --max-time 180 -o "$archive" "$url"; then
        err "下载失败：$url"; rm -rf -- "$stage"; return 1
    fi
    metadata=$(curl -fsSL --retry 1 --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${version}" 2>/dev/null) || metadata='{}'
    digest=$(jq -r --arg name "$asset" '.assets[]? | select(.name == $name) | .digest // empty' <<<"$metadata" 2>/dev/null) || digest=''
    if [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
        if [[ "$(sha256sum "$archive" | awk '{print $1}')" != "${BASH_REMATCH[1],,}" ]]; then
            err '下载文件 SHA256 与官方发布记录不一致。'; rm -rf -- "$stage"; return 1
        fi
    fi
    if ! tar -xzf "$archive" -C "$stage" "sing-box-${version}-linux-${SB_ARCH}/sing-box"; then
        err '官方压缩包解压失败。'; rm -rf -- "$stage"; return 1
    fi
    binary="$stage/sing-box-${version}-linux-${SB_ARCH}/sing-box"
    if [[ ! -f "$binary" || -L "$binary" ]] || ! chmod 700 "$binary" || ! "$binary" version; then
        err '下载的主程序无法运行。'; rm -rf -- "$stage"; return 1
    fi
    if [[ -e "$CONFIG_FILE" ]] && ! (cd "$WORK_DIR" && "$binary" check -c "$CONFIG_FILE"); then
        err '该版本无法通过现有配置检查，保留现有文件。'; rm -rf -- "$stage"; return 1
    fi
    if [[ -e "$SB_BIN" ]]; then
        err "目标程序已存在，拒绝覆盖：$SB_BIN"; rm -rf -- "$stage"; return 1
    fi
    if ! install -m 755 "$binary" "$SB_BIN"; then rm -rf -- "$stage"; return 1; fi
    rm -rf -- "$stage"
}

service_backend() {
    if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then printf systemd
    elif command -v rc-service >/dev/null; then printf openrc
    else err '需要 systemd 或 OpenRC 服务管理器。'; return 1; fi
}

ensure_service() {
    local backend unit existing user argv
    backend=$(service_backend) || return 1
    if [[ "$backend" == systemd ]]; then
        existing=$(systemctl show sing-box.service -p LoadState --value 2>/dev/null) || existing='not-found'
        if [[ "$existing" != not-found && -n "$existing" ]]; then
            existing=$(systemctl show sing-box.service -p ExecStart --value) || return 1
            user=$(systemctl show sing-box.service -p User --value) || return 1
            argv="${existing#*argv\[\]=}"
            [[ "$argv" != "$existing" ]] || { err '无法识别已有服务的启动参数，保留原服务。'; return 1; }
            argv="${argv%%;*}"
            argv=$(printf '%s' "$argv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ "$argv" != "$SB_BIN run -c $CONFIG_FILE" || ( -n "$user" && "$user" != root ) ]]; then
                err '发现服务使用其他程序、配置位置或用户。本工具保留该服务，请先核对接管方式。'; return 1
            fi
            return 0
        fi
        unit=/etc/systemd/system/sing-box.service
        [[ ! -e "$unit" ]] || { err "存在未加载的服务文件，保留：$unit"; return 1; }
        [[ "$WORK_DIR" == /etc/sing-box && "$SB_BIN" == /etc/sing-box/sing-box ]] || {
            err '自定义路径请自行配置匹配的服务文件。'; return 1;
        }
        cat > "$unit" <<'UNIT'
[Unit]
Description=sing-box independent proxy nodes
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload || return 1
    else
        unit=/etc/init.d/sing-box
        if [[ -e "$unit" ]]; then
            grep -Fxq "command=\"$SB_BIN\"" "$unit" && grep -Fxq "command_args=\"run -c $CONFIG_FILE\"" "$unit" || {
                err '已有 OpenRC 服务不匹配，保留原服务。'; return 1;
            }
            return 0
        fi
        [[ "$WORK_DIR" == /etc/sing-box && "$SB_BIN" == /etc/sing-box/sing-box ]] || return 1
        cat > "$unit" <<'UNIT'
#!/sbin/openrc-run
name="sing-box"
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
depend() { need net; }
UNIT
        chmod 755 "$unit" || return 1
    fi
}

svc_restart() {
    local backend
    backend=$(service_backend) || return 1
    if [[ "$backend" == systemd ]]; then
        systemctl restart sing-box.service || return 1
        sleep 1
        systemctl is-active --quiet sing-box.service || return 1
        systemctl enable sing-box.service >/dev/null || warn '服务已启动，但开机启动设置未成功。'
    else
        if rc-service sing-box status >/dev/null 2>&1; then rc-service sing-box restart; else rc-service sing-box start; fi || return 1
        sleep 1
        rc-service sing-box status >/dev/null || return 1
        rc-update add sing-box default >/dev/null || warn '开机启动设置未成功。'
    fi
}

svc_stop() {
    local backend; backend=$(service_backend) || return 1
    if [[ "$backend" == systemd ]]; then systemctl stop sing-box.service; else rc-service sing-box stop; fi
}

install_local_shortcut() {
    local self directory shortcut_directory temp='' shortcut_temp='' backup
    self=$(readlink -f -- "${BASH_SOURCE[0]}") || return 1
    [[ -f "$self" ]] || { err '请先将本脚本保存为文件再安装本地快捷命令。'; return 1; }
    [[ "$MANAGER_PATH" == /* && "$SHORTCUT_PATH" == /* && "$MANAGER_PATH" != "$SHORTCUT_PATH" ]] || {
        err '本地管理脚本与快捷命令必须使用不同的绝对路径。'; return 1;
    }
    directory=$(dirname -- "$MANAGER_PATH") && shortcut_directory=$(dirname -- "$SHORTCUT_PATH") || return 1
    mkdir -p -- "$directory" "$shortcut_directory" || return 1
    if [[ ( -d "$MANAGER_PATH" && ! -L "$MANAGER_PATH" ) || ( -d "$SHORTCUT_PATH" && ! -L "$SHORTCUT_PATH" ) ]]; then
        err '目标位置是目录，拒绝替换。'; return 1
    fi
    shortcut_temp=$(mktemp "$shortcut_directory/.menu-install.XXXXXX") || return 1
    if ! printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$MANAGER_PATH" > "$shortcut_temp" || ! chmod 755 "$shortcut_temp"; then
        rm -f -- "$shortcut_temp"; return 1
    fi
    if [[ "$self" != "$MANAGER_PATH" ]] && ! { [[ -f "$MANAGER_PATH" && ! -L "$MANAGER_PATH" ]] && cmp -s -- "$self" "$MANAGER_PATH"; }; then
        temp=$(mktemp "$directory/.manager-install.XXXXXX") || { rm -f -- "$shortcut_temp"; return 1; }
        if ! cp -- "$self" "$temp" || ! chmod 755 "$temp"; then
            rm -f -- "$temp" "$shortcut_temp"; return 1
        fi
        if [[ -e "$MANAGER_PATH" || -L "$MANAGER_PATH" ]]; then
            backup=$(mktemp -d "$directory/.manager-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || {
                rm -f -- "$temp" "$shortcut_temp"; return 1;
            }
            if ! cp -a -- "$MANAGER_PATH" "$backup/original"; then rm -f -- "$temp" "$shortcut_temp"; return 1; fi
            ok "原管理脚本已备份：$backup/original"
        fi
        # -T replaces a symlink itself, including one pointing to a directory.
        if ! mv -fT -- "$temp" "$MANAGER_PATH"; then rm -f -- "$temp" "$shortcut_temp"; return 1; fi
    fi
    if [[ -f "$SHORTCUT_PATH" && ! -L "$SHORTCUT_PATH" ]] && cmp -s -- "$shortcut_temp" "$SHORTCUT_PATH"; then
        rm -f -- "$shortcut_temp" || return 1
    else
        if [[ -e "$SHORTCUT_PATH" || -L "$SHORTCUT_PATH" ]]; then
            backup=$(mktemp -d "$shortcut_directory/.menu-backup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || {
                rm -f -- "$shortcut_temp"; return 1;
            }
            if ! cp -a -- "$SHORTCUT_PATH" "$backup/original"; then rm -f -- "$shortcut_temp"; return 1; fi
            ok "原快捷命令已备份：$backup/original"
        fi
        if ! mv -fT -- "$shortcut_temp" "$SHORTCUT_PATH"; then rm -f -- "$shortcut_temp"; return 1; fi
    fi
    ok "以后输入 $(basename -- "$SHORTCUT_PATH") 即可打开本地定制版；快捷命令只运行本机文件。"
}
#!/usr/bin/env bash
# Link generation only. Sourcing this module performs no I/O or network access.
# Public API: derive_reality_public_key PRIVATE_KEY
#             generate_links [INBOUND_TAG] [SERVER_OVERRIDE]
# CONFIG_FILE is authoritative; META_FILE optionally supplies node names/servers.

_links_error() { printf 'Link export: %s\n' "$*" >&2; }

_links_uri() { jq -nr --arg value "$1" '$value | @uri'; }

_links_base64() { base64 | tr -d '\r\n'; }

_links_base64url() { _links_base64 | tr '/+' '_-' | tr -d '='; }

# X25519 PKCS#8 contains a fixed 16-byte prefix followed by the 32-byte secret.
# Keep all secret material in pipes; never create a private-key temporary file.
derive_reality_public_key() (
  set -o pipefail
  local private_key=${1-} public_key
  if [[ ! $private_key =~ ^[A-Za-z0-9_-]{43}=?$ ]]; then
    _links_error 'REALITY private key must be a base64url-encoded 32-byte key.'
    return 1
  fi
  private_key=${private_key%=}
  if ! command -v openssl >/dev/null 2>&1; then
    _links_error 'OpenSSL is required to derive the REALITY public key.'
    return 1
  fi
  if ! public_key=$(
    {
      printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'
      printf '%s=' "$private_key" | tr '_-' '/+' | base64 --decode
    } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null |
      tail -c 32 | _links_base64url
  ); then
    _links_error 'Unable to derive the REALITY public key from the inbound private key.'
    return 1
  fi
  if [[ ! $public_key =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    _links_error 'OpenSSL returned an invalid REALITY public key.'
    return 1
  fi
  printf '%s\n' "$public_key"
)

_links_valid_ipv4() {
  local address=$1 octet
  local -a octets=()
  [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$address"
  for octet in "${octets[@]}"; do
    # Reject ambiguous octal-looking addresses as well as out-of-range octets.
    [[ $octet == 0 || $octet != 0* ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

_links_valid_ipv6() {
  local address=$1 left right group ipv4
  local -a left_groups=() right_groups=() groups=()
  [[ $address == *:* && $address =~ ^[A-Fa-f0-9:.]+$ && $address != *:::* ]] || return 1
  if [[ $address == *.* ]]; then
    ipv4=${address##*:}
    _links_valid_ipv4 "$ipv4" || return 1
    # An embedded IPv4 address occupies two of the eight hextets.
    address="${address%:*}:0:0"
  fi
  if [[ $address == *::* ]]; then
    left=${address%%::*}
    right=${address#*::}
    [[ $right != *::* ]] || return 1
    [[ -z $left ]] || IFS=: read -r -a left_groups <<<"$left"
    [[ -z $right ]] || IFS=: read -r -a right_groups <<<"$right"
    groups=("${left_groups[@]}" "${right_groups[@]}")
    # The compression marker must replace at least one hextet.
    ((${#groups[@]} < 8)) || return 1
  else
    [[ $address != :* && $address != *: ]] || return 1
    IFS=: read -r -a groups <<<"$address"
    ((${#groups[@]} == 8)) || return 1
  fi
  for group in "${groups[@]}"; do
    [[ $group =~ ^[A-Fa-f0-9]{1,4}$ ]] || return 1
  done
}

_links_valid_hostname() {
  local hostname=${1%.} label
  local -a labels=()
  [[ -n $hostname && ${#hostname} -le 253 && $hostname != *..* && $hostname != .* && $hostname != *. ]] || return 1
  IFS=. read -r -a labels <<<"$hostname"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

# URI authorities require brackets around IPv6; VMess JSON retains the bare host.
# Also used by the core's valid_server to reject invalid hosts before committing.
_links_server() {
  local server=${1-} valid=0
  [[ $server == \[*\] ]] && server=${server:1:${#server}-2}
  if [[ $server == *:* ]]; then
    _links_valid_ipv6 "$server" && valid=1
  elif [[ $server == *.* && $server =~ ^[0-9.]+$ ]]; then
    _links_valid_ipv4 "$server" && valid=1
  else
    _links_valid_hostname "$server" && valid=1
  fi
  if ((valid == 0)); then
    _links_error 'Use a valid IPv4 address, IPv6 address, or hostname without a protocol or port; legacy nodes need a server override.'
    return 1
  fi
  printf '%s\n' "$server"
}

_links_user_name() {
  local node_name=$1 user=$2 index=$3 count=$4 user_name
  if (( count > 1 )); then
    user_name=$(jq -r '.name // empty' <<<"$user") || return 1
    [[ -n $user_name ]] || user_name="user $index"
    printf '%s / %s\n' "$node_name" "$user_name"
  else
    printf '%s\n' "$node_name"
  fi
}

_links_render_inbound() (
  set -o pipefail
  local inbound=$1 metadata=$2 override=${3-}
  local tag protocol port server authority name users user count index=0
  local uuid flow sni short_id private_key public_key recorded_key query label
  local transport path host tls_mode json encoded method password server_password
  local -a links=()

  tag=$(jq -r '.tag // "(untagged)"' <<<"$inbound") || return 1
  protocol=$(jq -r '.type' <<<"$inbound") || return 1
  if ! port=$(jq -er '.listen_port | select(type == "number" and . == floor and . >= 1 and . <= 65535) | tostring' <<<"$inbound"); then
    _links_error "Inbound $tag has an invalid listening port."
    return 1
  fi
  if ! jq -e 'type == "object" and all([.name, .server, .public_key][]; . == null or type == "string")' <<<"$metadata" >/dev/null; then
    _links_error "Inbound $tag has invalid link metadata."
    return 1
  fi
  server=$override
  [[ -n $server ]] || server=$(jq -r '.server // empty' <<<"$metadata") || return 1
  server=$(_links_server "$server") || return 1
  authority=$server
  [[ $server != *:* ]] || authority="[$server]"
  name=$(jq -r '.name // empty' <<<"$metadata") || return 1
  [[ -n $name ]] || name=$tag

  case "$protocol" in
    vless|vmess)
      if ! jq -e '.users | type == "array" and length > 0 and all(.[]; type == "object" and (.uuid | type == "string" and length > 0))' <<<"$inbound" >/dev/null; then
        _links_error "Inbound $tag has no valid users."
        return 1
      fi
      users=$(jq -c '.users[]' <<<"$inbound") || return 1
      count=$(jq -r '.users | length' <<<"$inbound") || return 1
      ;;
    shadowsocks)
      method=$(jq -r '.method // empty' <<<"$inbound") || return 1
      server_password=$(jq -r '.password // empty' <<<"$inbound") || return 1
      if [[ -z $method || $method == *:* || $method == *[[:space:]]* ]]; then
        _links_error "Inbound $tag has an invalid Shadowsocks method."
        return 1
      fi
      if jq -e '.users | type == "array" and length > 0' <<<"$inbound" >/dev/null; then
        users=$(jq -c '.users[]' <<<"$inbound") || return 1
        count=$(jq -r '.users | length' <<<"$inbound") || return 1
      else
        users=$(jq -cn --arg password "$server_password" '{password:$password}') || return 1
        count=1
      fi
      ;;
    *) _links_error "Inbound $tag uses an unsupported protocol: $protocol."; return 1 ;;
  esac

  if [[ $protocol == vless ]]; then
    if ! jq -e '.tls.enabled == true and .tls.reality.enabled == true and ((.transport.type // "tcp") == "tcp")' <<<"$inbound" >/dev/null; then
      _links_error "Inbound $tag is not a supported VLESS TCP REALITY inbound."
      return 1
    fi
    private_key=$(jq -r '.tls.reality.private_key // empty' <<<"$inbound") || return 1
    public_key=$(derive_reality_public_key "$private_key") || return 1
    recorded_key=$(jq -r '.public_key // empty' <<<"$metadata") || return 1
    if [[ -n $recorded_key && ${recorded_key%=} != "$public_key" ]]; then
      _links_error "Inbound $tag metadata public key does not match its configured REALITY private key."
      return 1
    fi
    sni=$(jq -r 'if (.tls.server_name // "") != "" then .tls.server_name else (.tls.reality.handshake.server // "") end' <<<"$inbound") || return 1
    short_id=$(jq -er '(.tls.reality.short_id // [""]) | if type == "array" then (.[0] // "") else error("short_id must be an array") end | select(type == "string")' <<<"$inbound") || {
      _links_error "Inbound $tag has an invalid REALITY short ID."
      return 1
    }
    if [[ -z $sni || ! $short_id =~ ^([A-Fa-f0-9]{2}){0,8}$ ]]; then
      _links_error "Inbound $tag has an invalid REALITY server name or short ID."
      return 1
    fi
    query="encryption=none&security=reality&sni=$(_links_uri "$sni")&fp=chrome&pbk=$public_key&sid=$(_links_uri "$short_id")&type=tcp"
  elif [[ $protocol == vmess ]]; then
    transport=$(jq -r '.transport.type // empty' <<<"$inbound") || return 1
    if [[ $transport != ws ]]; then
      _links_error "Inbound $tag is not a supported VMess WebSocket inbound."
      return 1
    fi
    if jq -e '.tls.reality.enabled == true' <<<"$inbound" >/dev/null; then
      _links_error "Inbound $tag uses unsupported VMess REALITY settings."
      return 1
    fi
    path=$(jq -r '.transport.path // "/"' <<<"$inbound") || return 1
    host=$(jq -r '(.transport.headers.Host // .transport.headers.host // "") | if type == "array" then (.[0] // "") else . end' <<<"$inbound") || return 1
    sni=$(jq -r '.tls.server_name // empty' <<<"$inbound") || return 1
    tls_mode=$(jq -r 'if .tls.enabled == true then "tls" else "" end' <<<"$inbound") || return 1
  fi

  while IFS= read -r user; do
    index=$((index + 1))
    label=$(_links_user_name "$name" "$user" "$index" "$count") || return 1
    case "$protocol" in
      vless)
        uuid=$(jq -r '.uuid' <<<"$user") || return 1
        flow=$(jq -r '.flow // empty' <<<"$user") || return 1
        encoded=$query
        [[ -z $flow ]] || encoded+="&flow=$(_links_uri "$flow")"
        links+=("vless://$(_links_uri "$uuid")@$authority:$port?$encoded#$(_links_uri "$label")")
        ;;
      vmess)
        uuid=$(jq -r '.uuid' <<<"$user") || return 1
        # VMess carries JSON, so its raw path/name/SNI must be JSON escaped rather
        # than URI escaped; changing the path would change the WebSocket route.
        json=$(jq -cn --arg name "$label" --arg server "$server" --arg port "$port" \
          --arg uuid "$uuid" --arg host "$host" --arg path "$path" --arg tls "$tls_mode" \
          --arg sni "$sni" --argjson user "$user" \
          '{v:"2",ps:$name,add:$server,port:$port,id:$uuid,aid:(($user.alterId // $user.alter_id // 0)|tostring),net:"ws",type:"none",host:$host,path:$path,tls:$tls,sni:$sni,scy:"auto"}') || return 1
        encoded=$(printf '%s' "$json" | _links_base64) || return 1
        links+=("vmess://$encoded")
        ;;
      shadowsocks)
        password=$(jq -er '.password | select(type == "string" and length > 0)' <<<"$user") || {
          _links_error "Inbound $tag has an invalid Shadowsocks password."
          return 1
        }
        if [[ $method == 2022-* ]] && jq -e '.users | type == "array" and length > 0' <<<"$inbound" >/dev/null; then
          [[ -n $server_password ]] || { _links_error "Inbound $tag has no Shadowsocks server password."; return 1; }
          password="$server_password:$password"
        fi
        encoded=$(printf '%s:%s' "$method" "$password" | _links_base64url) || return 1
        links+=("ss://$encoded@$authority:$port#$(_links_uri "$label")")
        ;;
    esac
  done <<<"$users"
  printf '%s\n' "${links[@]}"
)

generate_links() (
  set -o pipefail
  local tag=${1-} override=${2-} metadata='{}' inbounds inbound inbound_tag node rendered
  local -a links=()
  if [[ -z ${CONFIG_FILE-} || ! -r $CONFIG_FILE ]]; then
    _links_error 'The runtime configuration is not readable.'
    return 1
  fi
  if ! jq -e 'type == "object" and (.inbounds | type == "array")' "$CONFIG_FILE" >/dev/null; then
    _links_error 'The runtime configuration must contain an inbounds array.'
    return 1
  fi
  if [[ -n ${META_FILE-} && -e $META_FILE ]]; then
    if ! metadata=$(jq -ce 'select(type == "object") | (.nodes // {}) | select(type == "object")' "$META_FILE"); then
      _links_error 'Node metadata is invalid or unreadable.'
      return 1
    fi
  fi
  if [[ -n $tag ]]; then
    if ! jq -e --arg tag "$tag" '[.inbounds[] | select(.tag == $tag)] | length == 1' "$CONFIG_FILE" >/dev/null; then
      _links_error "The inbound tag must identify exactly one inbound: $tag."
      return 1
    fi
    inbounds=$(jq -c --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE") || return 1
  else
    inbounds=$(jq -c '.inbounds[] | select(.type == "vless" or .type == "vmess" or .type == "shadowsocks")' "$CONFIG_FILE") || return 1
  fi
  if [[ -z $inbounds ]]; then
    _links_error 'No supported inbound is available for link export.'
    return 1
  fi
  while IFS= read -r inbound; do
    inbound_tag=$(jq -r '.tag // empty' <<<"$inbound") || return 1
    node=$(jq -c --arg tag "$inbound_tag" '.[$tag] // {}' <<<"$metadata") || return 1
    rendered=$(_links_render_inbound "$inbound" "$node" "$override") || return 1
    links+=("$rendered")
  done <<<"$inbounds"
  # Buffer first: an invalid later inbound must not leave partially valid output.
  printf '%s\n' "${links[@]}"
)
# Quota prerequisites and systemd integration. Rule/state operations live elsewhere.
quota_system_paths_ok() {
    [[ "$WORK_DIR" == /etc/sing-box && "$CONFIG_FILE" == /etc/sing-box/config.json &&
       "$STATE_DIR" == /etc/sing-box/node-manager && "$SB_BIN" == /etc/sing-box/sing-box &&
       "$MANAGER_PATH" == /usr/local/lib/proxy-node-manager/manager.sh ]] || {
        err '自动流量服务只支持标准 /etc/sing-box 与 /usr/local/lib/proxy-node-manager/manager.sh 路径；自定义路径请自行配置服务。'; return 1;
    }
    [[ "$(service_backend)" == systemd ]] || { err '自动流量服务需要运行中的 systemd。'; return 1; }
}

ensure_quota_dependencies() {
    quota_system_paths_ok || return 1
    ensure_dependencies || return 1
    local nft_command="${NFT_BIN:-${PROXY_NFT_BIN:-nft}}" tables probe probe_table
    if ! command -v "$nft_command" >/dev/null; then
        [[ "$nft_command" == nft ]] || { err "指定的 nft 程序不存在：$nft_command"; return 1; }
        ok '安装 nftables 流量额度依赖。'
        if command -v apt-get >/dev/null; then
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nftables || return 1
        elif command -v dnf >/dev/null; then dnf install -y nftables || return 1
        elif command -v yum >/dev/null; then yum install -y nftables || return 1
        elif command -v pacman >/dev/null; then pacman -S --needed --noconfirm nftables || return 1
        else err '请先手动安装 nftables。'; return 1
        fi
    fi
    command -v "$nft_command" >/dev/null || { err 'nftables 安装后仍无法找到 nft。'; return 1; }
    tables=$("$nft_command" -j list tables) || { err '无法读取 nftables；请检查内核支持及 CAP_NET_ADMIN 权限。'; return 1; }
    jq -e 'type == "object" and (.nftables | type == "array")' <<<"$tables" >/dev/null || {
        err 'nftables 未返回可识别的 JSON。'; return 1;
    }
    probe_table="pnm_probe_${BASHPID}_${RANDOM}_${RANDOM}"
    jq -e --arg t "$probe_table" 'any(.nftables[]?.table?; .family == "inet" and .name == $t) | not' <<<"$tables" >/dev/null || {
        err '能力检查临时表名冲突，请重试。'; return 1;
    }
    probe=$(mktemp "${TMPDIR:-/tmp}/pnm-nft-check.XXXXXXXX") || return 1
    if ! cat > "$probe" <<NFT
table inet $probe_table {
    comment "proxy-node-manager capability check"
    quota probe_q { over 1000000 bytes used 0 bytes; }
    counter probe_c { packets 0 bytes 0; }
    chain probe_input {
        type filter hook input priority -150; policy accept;
        tcp dport 65534 quota name "probe_q" drop
        udp dport 65534 counter name "probe_c"
    }
    chain probe_output {
        type filter hook output priority -150; policy accept;
        tcp sport 65534 quota name "probe_q" drop
        udp sport 65534 counter name "probe_c"
    }
}
NFT
    then rm -f -- "$probe"; return 1; fi
    # --check validates the complete transaction but does not install this table.
    if ! "$nft_command" -c -f "$probe"; then
        rm -f -- "$probe"
        err '内核/nftables 无法通过命名额度、计数器与双向过滤能力检查；现有代理未因此停止。'; return 1
    fi
    rm -f -- "$probe" || return 1
}

quota_service_unit() {
    cat <<'UNIT'
# Managed by proxy-node-manager quota service v1.
[Unit]
Description=proxy-node-manager cumulative traffic quotas
Wants=network-online.target
After=network-online.target nftables.service firewalld.service
Before=sing-box.service

[Service]
Type=simple
User=root
UMask=0077
WorkingDirectory=/etc/sing-box
ExecStartPre=/bin/bash /usr/local/lib/proxy-node-manager/manager.sh --quota-restore
ExecStart=/bin/bash /usr/local/lib/proxy-node-manager/manager.sh --quota-daemon
Restart=on-failure
RestartSec=3
TimeoutStartSec=60
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=multi-user.target
UNIT
}

quota_singbox_dropin() {
    cat <<'UNIT'
# Managed by proxy-node-manager quota service v1.
[Unit]
Requires=proxy-node-quota.service
After=proxy-node-quota.service
UNIT
}

# Only create an absent regular file or accept byte-identical owned content.
# Hard-linking the prepared file is atomic and never overwrites a raced-in path.
quota_install_service_file() {
    local destination="$1" generator="$2" parent temp
    QUOTA_FILE_CREATED=0
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] && cmp -s -- "$destination" <("$generator") || {
            err "发现外来或修改过的服务文件，保留原文件：$destination"; return 1;
        }
        return 0
    fi
    parent=$(dirname -- "$destination") || return 1
    temp=$(mktemp "$parent/.pnm-unit.XXXXXX") || return 1
    if ! "$generator" > "$temp" || ! chmod 644 "$temp" || ! ln -T -- "$temp" "$destination"; then
        rm -f -- "$temp"; return 1
    fi
    QUOTA_FILE_CREATED=1
    rm -f -- "$temp" || return 1
}

quota_service_files_match() {
    local unit=/etc/systemd/system/proxy-node-quota.service
    local dropin=/etc/systemd/system/sing-box.service.d/20-proxy-node-quota.conf
    [[ -f "$unit" && ! -L "$unit" && -f "$dropin" && ! -L "$dropin" &&
       ! -L /etc/systemd/system/sing-box.service.d ]] &&
        cmp -s -- "$unit" <(quota_service_unit) && cmp -s -- "$dropin" <(quota_singbox_dropin)
}

quota_effective_service_matches() {
    local fragment overrides requires after dropins
    fragment=$(systemctl show proxy-node-quota.service -p FragmentPath --value) &&
        overrides=$(systemctl show proxy-node-quota.service -p DropInPaths --value) &&
        requires=$(systemctl show sing-box.service -p Requires --value) &&
        after=$(systemctl show sing-box.service -p After --value) &&
        dropins=$(systemctl show sing-box.service -p DropInPaths --value) || return 1
    [[ "$fragment" == /etc/systemd/system/proxy-node-quota.service && -z "$overrides" &&
       " $requires " == *' proxy-node-quota.service '* && " $after " == *' proxy-node-quota.service '* &&
       " $dropins " == *' /etc/systemd/system/sing-box.service.d/20-proxy-node-quota.conf '* ]]
}

quota_install_service() {
    quota_system_paths_ok || return 1
    [[ -x /bin/bash && -f "$MANAGER_PATH" && ! -L "$MANAGER_PATH" ]] || {
        err '请先安装标准路径的本地管理脚本及 /bin/bash。'; return 1;
    }
    local unit=/etc/systemd/system/proxy-node-quota.service
    local dropin_dir=/etc/systemd/system/sing-box.service.d
    local dropin="$dropin_dir/20-proxy-node-quota.conf" fragment unit_created=0 dropin_created=0 was_enabled=0
    # Check the manager bus separately; nonexistent units may make show exit nonzero.
    systemctl show -p Version --value >/dev/null || return 1
    fragment=$(systemctl show proxy-node-quota.service -p FragmentPath --value 2>/dev/null) || fragment=''
    [[ -z "$fragment" || "$fragment" == "$unit" ]] || {
        err "已有外来流量服务，拒绝覆盖：$fragment"; return 1;
    }
    [[ ! -L "$dropin_dir" && ( ! -e "$dropin_dir" || -d "$dropin_dir" ) ]] || {
        err "服务覆盖目录不是普通目录，拒绝写入：$dropin_dir"; return 1;
    }
    mkdir -p -- "$dropin_dir" || return 1
    systemctl is-enabled --quiet proxy-node-quota.service 2>/dev/null && was_enabled=1
    if quota_install_service_file "$unit" quota_service_unit; then
        unit_created=$QUOTA_FILE_CREATED
        if quota_install_service_file "$dropin" quota_singbox_dropin; then
            dropin_created=$QUOTA_FILE_CREATED
            if systemctl daemon-reload && quota_effective_service_matches && systemctl enable proxy-node-quota.service >/dev/null; then
                return 0
            fi
        fi
    fi
    # Roll back only files created by this call and still containing our bytes.
    if ((was_enabled == 0)); then systemctl disable proxy-node-quota.service >/dev/null 2>&1 || warn '流量服务开机链接清理失败，请检查 systemctl is-enabled。'; fi
    if ((dropin_created)) && [[ -f "$dropin" && ! -L "$dropin" ]] && cmp -s -- "$dropin" <(quota_singbox_dropin); then
        rm -f -- "$dropin" || warn "无法撤回本次创建的覆盖文件：$dropin"
    fi
    if ((unit_created)) && [[ -f "$unit" && ! -L "$unit" ]] && cmp -s -- "$unit" <(quota_service_unit); then
        rm -f -- "$unit" || warn "无法撤回本次创建的服务文件：$unit"
    fi
    systemctl daemon-reload || warn '撤回安装后的 systemd 重新加载失败。'
    err '流量服务安装未完成；未启动或停止现有代理。'; return 1
}

quota_start_service() {
    [[ "${LOCK_HELD:-0}" == 0 ]] || { err '必须先释放节点管理锁，再启动流量服务，以免启动前恢复流程死锁。'; return 1; }
    quota_system_paths_ok && quota_service_files_match && quota_effective_service_matches || return 1
    systemctl start proxy-node-quota.service && systemctl is-active --quiet proxy-node-quota.service
}

quota_service_ready() {
    quota_system_paths_ok && quota_service_files_match && quota_effective_service_matches &&
        systemctl is-active --quiet proxy-node-quota.service
}
# Cumulative, per-listener packet quotas. Only this manager's inet table is used.
TRAFFIC_FILE="${STATE_DIR}/traffic-state.json"
TRAFFIC_ENABLED="${STATE_DIR}/traffic-enabled"
NFT_BIN="${PROXY_NFT_BIN:-nft}"
QUOTA_TABLE='pnm_traffic'
QUOTA_OWNER='proxy-node-manager quotas v1'
QUOTA_MAX_BYTES=1000000000000000

quota_enabled() { [[ -f "$TRAFFIC_ENABLED" ]]; }
quota_valid_bytes() { [[ "$1" =~ ^(0|[1-9][0-9]{0,15})$ ]] && ((10#$1 <= QUOTA_MAX_BYTES)); }
quota_parse_gb() {
    local value="$1" whole fraction
    [[ "$value" =~ ^(0|[1-9][0-9]{0,6})(\.[0-9]{1,3})?$ ]] || { err '额度请输入 GB 数值，最多三位小数；0 表示不限量。'; return 1; }
    whole=${value%%.*}; fraction=''
    [[ "$value" != *.* ]] || fraction=${value#*.}
    fraction="${fraction}000"; fraction=${fraction:0:3}
    local bytes=$((10#$whole * 1000000000 + 10#$fraction * 1000000))
    quota_valid_bytes "$bytes" || { err '额度最多 1000000 GB。'; return 1; }
    printf '%s\n' "$bytes"
}

quota_read_state() {
    if [[ ! -f "$TRAFFIC_FILE" ]]; then
        if quota_enabled; then err '流量状态文件丢失，拒绝按零用量恢复。请恢复备份。'; return 1; fi
        printf '{"version":1,"nodes":{}}\n'; return 0
    fi
    jq -e --argjson max "$QUOTA_MAX_BYTES" '
      def uint: type == "number" and . >= 0 and . <= $max and . == floor;
      if type == "object" and .version == 1 and (.nodes | type == "object") and
         all(.nodes[]; type == "object" and (.used_bytes | uint) and
             (.epoch | type == "number" and . >= 0 and . <= 1000000000 and . == floor))
      then . else error("invalid traffic state; refusing zero fallback") end' "$TRAFFIC_FILE"
}

quota_write_state() {
    local json="$1" temp
    temp=$(mktemp "$STATE_DIR/traffic.XXXXXX") || return 1
    if ! printf '%s\n' "$json" > "$temp" || ! chmod 600 "$temp" || ! mv -f -- "$temp" "$TRAFFIC_FILE"; then
        rm -f -- "$temp"; err '流量记录保存失败，原记录保留。'; return 1
    fi
}

quota_object_id() {
    local tag="$1" epoch="$2" kind="$3"
    [[ "$tag" =~ ^pnm-(vless|vmess|shadowsocks)-[0-9a-f]{16}$ && "$epoch" =~ ^[0-9]{1,10}$ ]] || return 1
    tag=${tag//-/_}
    printf '%s_%s_g%s\n' "$kind" "$tag" "$epoch"
}

# nft 1.0.2 omits table comments from JSON. Verify its native table-level
# comment and table handle before supplying that one missing JSON field.
# An explicit JSON comment, including null or a foreign value, never falls back.
quota_native_table_owned() {
    local native="$1" handle="$2"
    [[ "$handle" =~ ^[1-9][0-9]*$ ]] || return 1
    awk -v header="table inet $QUOTA_TABLE { # handle $handle" \
        -v owner="\tcomment \"$QUOTA_OWNER\"" '
      BEGIN { depth=0; quoted=0; escaped=0; owners=0; bad=0 }
      NR == 1 { if ($0 != header) bad=1 }
      {
        if (NR > 1 && depth == 0 && $0 !~ /^[[:space:]]*$/) bad=1;
        if (depth == 1 && $0 ~ /^[[:space:]]*comment[[:space:]]/) {
          owners++; if ($0 != owner) bad=1;
        }
        for (i=1; i<=length($0); i++) {
          c=substr($0,i,1);
          if (quoted) {
            if (escaped) escaped=0;
            else if (c == "\\") escaped=1;
            else if (c == "\"") quoted=0;
          } else {
            if (c == "#") break;
            if (c == "\"") quoted=1;
            else if (c == "{") depth++;
            else if (c == "}") { depth--; if (depth < 0) bad=1 }
          }
        }
        if (quoted) bad=1;
      }
      END { exit (bad || NR < 3 || depth != 0 || owners != 1) }
    ' <<<"$native"
}

quota_kernel_owner_json() {
    local json="$1" handle native
    if jq -e --arg t "$QUOTA_TABLE" \
        'any(.nftables[]?.table?; .family == "inet" and .name == $t and has("comment"))' \
        <<<"$json" >/dev/null; then
        printf '%s\n' "$json"; return 0
    fi
    handle=$(jq -er --arg t "$QUOTA_TABLE" '
      [.nftables[]?.table? | select(.family == "inet" and .name == $t)] |
      if length == 1 and (.[0].handle | type == "number" and . > 0 and . == floor)
      then .[0].handle else error("invalid table identity") end' <<<"$json") || return 1
    native=$("$NFT_BIN" -a list table inet "$QUOTA_TABLE") || return 1
    quota_native_table_owned "$native" "$handle" || {
        err '旧版 nftables 的原生输出无法确认流量表归属，保留现状。'; return 1;
    }
    jq --arg t "$QUOTA_TABLE" --arg owner "$QUOTA_OWNER" \
        '(.nftables[] | select(has("table")) | .table |
          select(.family == "inet" and .name == $t) | .comment) = $owner' <<<"$json"
}

# A failure to read an existing table is not treated as an empty counter.
quota_read_kernel() {
    local json tables
    if json=$("$NFT_BIN" -j list table inet "$QUOTA_TABLE" 2>/dev/null); then
        json=$(quota_kernel_owner_json "$json") || return 1
        quota_validate_kernel "$json" || return 1
        printf '%s\n' "$json"; return 0
    fi
    tables=$("$NFT_BIN" -j list tables) || return 1
    jq -e --arg t "$QUOTA_TABLE" '(.nftables | type == "array") and
      (any(.nftables[]?.table?; .family == "inet" and .name == $t) | not)' <<<"$tables" >/dev/null || {
        err '流量表存在但无法读取，拒绝清零或覆盖。'; return 1;
    }
    printf '{"nftables":[]}\n'
}

quota_validate_kernel() {
    jq -e --arg t "$QUOTA_TABLE" --arg owner "$QUOTA_OWNER" --argjson max "$QUOTA_MAX_BYTES" '
      def uint: type == "number" and . >= 0 and . <= $max and . == floor;
      (.nftables | type == "array") and
      ([.nftables[]?.table? | select(.family == "inet" and .name == $t and .comment == $owner)] | length) == 1 and
      ([.nftables[]?.chain? | select(.family == "inet" and .table == $t and
        (.name == "input" or .name == "output") and .type == "filter" and .hook == .name and .prio == -150 and .policy == "accept")] | length) == 2 and
      all(.nftables[] | .quota? // .counter? // empty;
        .family == "inet" and .table == $t and
        (.name | test("^[qc]_pnm_(vless|vmess|shadowsocks)_[0-9a-f]{16}_g[0-9]{1,10}$")) and
        (if has("used") then (.used | uint) and (.bytes | uint) and .bytes > 0 and .used <= .bytes and .inv == true
         else (.bytes | uint) and (.packets | uint) end)) and
      ([.nftables[] | .quota? // .counter? // empty | .name] as $names | ($names | length) == ($names | unique | length))
      ' <<<"$1" >/dev/null || { err '流量表的归属、对象或数值异常，保留现状。'; return 1; }
}

# Compare live rule expressions and object identities with the configured nodes.
# This detects a table/chain flush even when the owned table header survives.
quota_enforcement_valid() {
    local kernel="$1" state metadata config
    state=$(quota_read_state) && metadata=$(read_metadata) && config=$(read_current_config) || return 1
    jq -e --argjson s "$state" --argjson m "$metadata" --argjson cfg "$config" --arg t "$QUOTA_TABLE" '
      def sort_rules: sort_by(.chain,.expr[0].match.left.payload.protocol,.expr[0].match.right);
      [$cfg.inbounds[]? | select($m.nodes[.tag // ""] != null) | . as $n |
        ($m.nodes[.tag].quota_bytes // 0) as $limit | ($s.nodes[.tag].used_bytes // 0) as $used |
        ($s.nodes[.tag].epoch // 0) as $epoch |
        (if $limit > 0 then "q" else "c" end) as $kind |
        {id:($kind+"_"+(.tag | gsub("-";"_"))+"_g"+($epoch|tostring)),
         kind:$kind,port:.listen_port,used:$used,limit:([$used,$limit]|max)}] as $nodes |
      [.nftables[] | .quota? // .counter? // empty] as $objects |
      ($objects | length) == ($nodes | length) and
      all($nodes[]; . as $n |
        any($objects[]; .name == $n.id and
          (if $n.kind == "q" then .inv == true and .bytes == $n.limit and .used >= $n.used
           else has("packets") and .bytes >= $n.used end))) and
      (([$nodes[] | . as $n | ["input","output"][] as $chain | ["tcp","udp"][] as $protocol |
        {chain:$chain,expr:([{match:{op:"==",left:{payload:{protocol:$protocol,
           field:(if $chain=="input" then "dport" else "sport" end)}},right:$n.port}}] +
          (if $n.kind == "q" then [{quota:$n.id},{drop:null}] else [{counter:$n.id}] end))}] | sort_rules) as $expected |
      ([.nftables[]?.rule? | select(.family == "inet" and .table == $t) |
        {chain:.chain,expr:.expr}] | sort_rules) == $expected)
      ' <<<"$kernel" >/dev/null
}

# Caller holds the manager lock. Disk is monotonically nondecreasing per epoch.
quota_snapshot_json() {
    local kernel="$1" state metadata tag epoch qid cid used old now tags
    state=$(quota_read_state) && metadata=$(read_metadata) || return 1
    now=$(date -u +%FT%TZ)
    tags=$(jq -r '.nodes | keys[]' <<<"$metadata") || return 1
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        epoch=$(jq -r --arg tag "$tag" '.nodes[$tag].epoch // 0' <<<"$state")
        qid=$(quota_object_id "$tag" "$epoch" q) && cid=$(quota_object_id "$tag" "$epoch" c) || return 1
        used=$(jq -r --arg q "$qid" --arg c "$cid" '[.nftables[] | .quota? // .counter? // empty |
          select(.name == $q or .name == $c) | (.used // .bytes)] | if length == 0 then "" elif length == 1 then .[0] else error("duplicate node counters") end' <<<"$kernel") || return 1
        old=$(jq -r --arg tag "$tag" '.nodes[$tag].used_bytes // 0' <<<"$state")
        [[ -n "$used" ]] || used="$old"
        quota_valid_bytes "$used" || { err '节点流量超出可表示范围，拒绝改写记录。'; return 1; }
        ((used >= old)) || used="$old"
        state=$(jq --arg tag "$tag" --argjson used "$used" --argjson epoch "$epoch" --arg now "$now" \
          '.nodes[$tag] = {used_bytes:$used,epoch:$epoch,updated_at:$now}' <<<"$state") || return 1
    done <<<"$tags"
    quota_write_state "$state"
}

quota_snapshot() {
    local kernel
    kernel=$(quota_read_kernel) || return 1
    quota_snapshot_json "$kernel"
}

# Guard client-facing ports while replacing quota limits or accounting epochs.
# It is removed by the final atomic batch; errors leave it fail-closed.
quota_guard() {
    local kernel="$1" config metadata ports port batch
    config=$(read_current_config) && metadata=$(read_metadata) || return 1
    ports=$(jq -r --argjson m "$metadata" '[.inbounds[]? | select($m.nodes[.tag // ""] != null) | .listen_port] | unique[]' <<<"$config") || return 1
    batch=$(mktemp "$STATE_DIR/guard.XXXXXX") || return 1
    if ! jq -e 'any(.nftables[]; has("table"))' <<<"$kernel" >/dev/null; then
        printf 'add table inet %s { comment "%s"; }\n' "$QUOTA_TABLE" "$QUOTA_OWNER" > "$batch"
        printf 'add chain inet %s input { type filter hook input priority -150; policy accept; }\n' "$QUOTA_TABLE" >> "$batch"
        printf 'add chain inet %s output { type filter hook output priority -150; policy accept; }\n' "$QUOTA_TABLE" >> "$batch"
    fi
    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        valid_port "$port" || { rm -f -- "$batch"; return 1; }
        printf 'insert rule inet %s input tcp dport %s drop comment "maintenance"\n' "$QUOTA_TABLE" "$port" >> "$batch"
        printf 'insert rule inet %s input udp dport %s drop comment "maintenance"\n' "$QUOTA_TABLE" "$port" >> "$batch"
        printf 'insert rule inet %s output tcp sport %s drop comment "maintenance"\n' "$QUOTA_TABLE" "$port" >> "$batch"
        printf 'insert rule inet %s output udp sport %s drop comment "maintenance"\n' "$QUOTA_TABLE" "$port" >> "$batch"
    done <<<"$ports"
    if [[ -s "$batch" ]]; then
        "$NFT_BIN" -c -f "$batch" && "$NFT_BIN" -f "$batch" || { rm -f -- "$batch"; return 1; }
    fi
    rm -f -- "$batch"
}

# Generate only validated identifiers/numbers, never interpolated user names.
# Existing objects are retained unless limit/kind/epoch must change.
quota_build_batch() {
    local kernel="$1" state metadata config tag port limit used epoch kind id effective old_type old_limit old_used name
    local wanted='[]' spec entries obsolete
    state=$(quota_read_state) && metadata=$(read_metadata) && config=$(read_current_config) || return 1
    entries=$(jq -r --argjson m "$metadata" '.inbounds[]? | select($m.nodes[.tag // ""] != null) |
      [.tag,.listen_port,($m.nodes[.tag // ""].quota_bytes // 0)] | @tsv' <<<"$config") || return 1
    if ! jq -e 'any(.nftables[]; has("table"))' <<<"$kernel" >/dev/null; then
        printf 'add table inet %s { comment "%s"; }\n' "$QUOTA_TABLE" "$QUOTA_OWNER"
        printf 'add chain inet %s input { type filter hook input priority -150; policy accept; }\n' "$QUOTA_TABLE"
        printf 'add chain inet %s output { type filter hook output priority -150; policy accept; }\n' "$QUOTA_TABLE"
    else
        printf 'flush chain inet %s input\nflush chain inet %s output\n' "$QUOTA_TABLE" "$QUOTA_TABLE"
    fi
    while IFS=$'\t' read -r tag port limit; do
        [[ -n "$tag" ]] || continue
        valid_port "$port" && quota_valid_bytes "$limit" || return 1
        used=$(jq -r --arg t "$tag" '.nodes[$t].used_bytes // 0' <<<"$state")
        epoch=$(jq -r --arg t "$tag" '.nodes[$t].epoch // 0' <<<"$state")
        if ((limit > 0)); then kind=q; else kind=c; fi
        id=$(quota_object_id "$tag" "$epoch" "$kind") || return 1
        wanted=$(jq -c --arg id "$id" '. + [$id]' <<<"$wanted") || return 1
        spec=$(jq -c --arg id "$id" '[.nftables[] | .quota? // .counter? // empty | select(.name == $id)] | .[0] // {}' <<<"$kernel") || return 1
        old_type=$(jq -r 'if has("used") then "q" elif has("packets") then "c" else "none" end' <<<"$spec")
        old_used=$(jq -r '.used // .bytes // 0' <<<"$spec")
        old_limit=$(jq -r '.bytes // 0' <<<"$spec")
        effective="$limit"; ((effective >= used)) || effective="$used"
        if [[ "$old_type" != "$kind" ]] || ((old_used < used)) || { [[ "$kind" == q ]] && ((old_limit != effective)); }; then
            if [[ "$old_type" != none ]]; then
                if [[ "$old_type" == q ]]; then name=quota; else name=counter; fi
                printf 'delete %s inet %s %s\n' "$name" "$QUOTA_TABLE" "$id"
            fi
            if [[ "$kind" == q ]]; then
                printf 'add quota inet %s %s { over %s bytes used %s bytes; }\n' "$QUOTA_TABLE" "$id" "$effective" "$used"
            else
                printf 'add counter inet %s %s { packets 0 bytes %s; }\n' "$QUOTA_TABLE" "$id" "$used"
            fi
        fi
        if [[ "$kind" == q ]]; then spec="quota name \"$id\" drop"; else spec="counter name \"$id\""; fi
        printf 'add rule inet %s input tcp dport %s %s\n' "$QUOTA_TABLE" "$port" "$spec"
        printf 'add rule inet %s input udp dport %s %s\n' "$QUOTA_TABLE" "$port" "$spec"
        printf 'add rule inet %s output tcp sport %s %s\n' "$QUOTA_TABLE" "$port" "$spec"
        printf 'add rule inet %s output udp sport %s %s\n' "$QUOTA_TABLE" "$port" "$spec"
    done <<<"$entries"
    obsolete=$(jq -r --argjson wanted "$wanted" '.nftables[] |
      if has("quota") then ["quota",.quota.name] elif has("counter") then ["counter",.counter.name] else empty end |
      select(.[1] as $id | ($wanted | index($id)) == null) | @tsv' <<<"$kernel") || return 1
    while IFS=$'\t' read -r name id; do
        [[ -n "$id" ]] && printf 'delete %s inet %s %s\n' "$name" "$QUOTA_TABLE" "$id"
    done <<<"$obsolete"
    return 0
}

quota_sync() {
    local kernel batch
    quota_enabled || return 0
    kernel=$(quota_read_kernel) || return 1
    quota_guard "$kernel" || return 1
    kernel=$(quota_read_kernel) && quota_snapshot_json "$kernel" || return 1
    batch=$(mktemp "$STATE_DIR/quota.XXXXXX") || return 1
    if ! quota_build_batch "$kernel" > "$batch" || ! "$NFT_BIN" -c -f "$batch" || ! "$NFT_BIN" -f "$batch"; then
        rm -f -- "$batch"; err '流量规则未能应用，维护阻断规则保留。'; return 1
    fi
    rm -f -- "$batch"
    kernel=$(quota_read_kernel) && quota_enforcement_valid "$kernel" || {
        err '流量规则应用后的核验失败。'; return 1;
    }
}

quota_restore() (
    acquire_lock || return 1
    quota_enabled || { err '尚未启用流量管理。'; return 1; }
    quota_read_state >/dev/null && quota_sync
)

# Install/start outside a held manager lock: ExecStartPre obtains that lock.
quota_enable_runtime() {
    ensure_quota_dependencies && ensure_service && install_local_shortcut && quota_install_service || return 1
    (
        acquire_lock || return 1
        if ! quota_enabled; then
            local state marker
            state=$(quota_read_state) || return 1
            quota_write_state "$state" || return 1
            marker=$(mktemp "$STATE_DIR/enabled.XXXXXX") || return 1
            printf 'cumulative-manual-reset-v1\n' > "$marker" && chmod 600 "$marker" && mv -f -- "$marker" "$TRAFFIC_ENABLED" || {
                rm -f -- "$marker"; return 1;
            }
        fi
    ) || return 1
    quota_start_service || { svc_stop || true; err '流量服务启动失败，已尝试停止代理以防绕过额度。'; return 1; }
}

quota_set_limit() (
    local tag="$1" bytes="$2" metadata backup candidate
    acquire_lock && require_managed_node "$tag" || return 1
    quota_valid_bytes "$bytes" || { err '无效的字节额度。'; return 1; }
    quota_enabled && quota_service_ready || { err '请先启用并启动流量服务。'; return 1; }
    quota_snapshot || return 1
    metadata=$(read_metadata) || return 1
    backup=$(mktemp "$BACKUP_DIR/quota-meta.XXXXXX") && cp -p -- "$META_FILE" "$backup" || return 1
    candidate=$(mktemp "$STATE_DIR/meta-quota.XXXXXX") || return 1
    jq --arg t "$tag" --argjson n "$bytes" '.nodes[$t].quota_bytes=$n' <<<"$metadata" > "$candidate" &&
      chmod 600 "$candidate" && mv -f -- "$candidate" "$META_FILE" || { rm -f -- "$candidate"; return 1; }
    if quota_sync; then ok '该节点累计额度已更新，已用流量保留。'; return 0; fi
    candidate=$(mktemp "$STATE_DIR/meta-quota-restore.XXXXXX") || { svc_stop || true; return 1; }
    if ! cp -p -- "$backup" "$candidate" || ! mv -f -- "$candidate" "$META_FILE" || ! quota_sync; then
        rm -f -- "$candidate"; svc_stop || true
        err '额度修改回滚未完成，已尝试停止代理。'
    fi
    return 1
)

quota_reset_usage() (
    local tag="$1" state epoch kernel now
    acquire_lock && require_managed_node "$tag" || return 1
    quota_enabled && quota_service_ready || { err '请先启用并启动流量服务。'; return 1; }
    kernel=$(quota_read_kernel) && quota_guard "$kernel" && quota_snapshot || return 1
    state=$(quota_read_state) || return 1
    epoch=$(jq -r --arg t "$tag" '(.nodes[$t].epoch // 0) + 1' <<<"$state")
    ((epoch <= 1000000000)) || { err '重置代数超出范围。'; return 1; }
    now=$(date -u +%FT%TZ)
    state=$(jq --arg t "$tag" --argjson e "$epoch" --arg now "$now" \
      '.nodes[$t]={used_bytes:0,epoch:$e,updated_at:$now}' <<<"$state") || return 1
    # Persist the authorized new epoch before changing the kernel. A retry uses
    # the same epoch, so a crash cannot repeatedly grant fresh allowances.
    quota_write_state "$state" && quota_sync || {
        svc_stop || true; err '清零请求未完全应用，已尝试停止代理；记录保留，请从菜单检查并重启。'; return 1;
    }
    ok '仅选中节点已用流量归零；原额度保留。'
)

quota_show_usage() (
    local state metadata config kernel
    acquire_lock || return 1
    quota_enabled || { ok '尚未启用流量管理；启用之前的历史流量无法补算。'; return 0; }
    kernel=$(quota_read_kernel) && quota_enforcement_valid "$kernel" && quota_snapshot_json "$kernel" || {
        err '实时限额规则未通过核验，请先从菜单检查并重启。'; return 1;
    }
    state=$(quota_read_state) && metadata=$(read_metadata) && config=$(read_current_config) || return 1
    printf '名称\t端口\t已用 GB\t累计额度 GB\t额度状态\n'
    jq -r --argjson s "$state" --argjson m "$metadata" '.inbounds[]? | select($m.nodes[.tag // ""] != null) |
      . as $i | ($s.nodes[.tag].used_bytes // 0) as $u | ($m.nodes[.tag // ""].quota_bytes // 0) as $l |
      [$m.nodes[.tag // ""].name,.listen_port,($u/1000000000),
       (if $l == 0 then "不限量" else ($l/1000000000) end),
       (if $l > 0 and $u >= $l then "额度用完/阻断" else "额度内" end)] | @tsv' <<<"$config"
)

quota_tick() (
    # Lock contention is routine while a short manager transaction is active.
    prepare_workspace || return 1
    exec 9>"$STATE_DIR/manager.lock" || return 1
    flock -n 9 || return 75
    LOCK_HELD=1
    local kernel
    kernel=$(quota_read_kernel) || return 1
    if quota_enforcement_valid "$kernel"; then
        quota_snapshot_json "$kernel"
    else
        quota_sync
    fi
)

quota_daemon() {
    local status
    trap 'quota_tick >/dev/null 2>&1 || true; exit 0' TERM INT
    while true; do
        quota_tick; status=$?
        if ((status != 0 && status != 75)); then
            svc_stop || true
            err '流量监控失败，已尝试停止代理；请检查流量服务日志。'
            return 1
        fi
        sleep 5 & wait $! || true
    done
}
# Interactive menu. Opening the menu never merges or cleans node configs.
detect_public_address() {
    local detected
    detected=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null) || detected=''
    if valid_server "$detected"; then printf '%s\n' "$detected"; fi
}

ask_server() {
    local default="${1:-}" entered
    [[ -n "$default" ]] || default=$(detect_public_address)
    prompt_read "节点连接地址（仅 IP/域名，不含协议端口）[${default:-请填写}]：" entered || return 1
    SERVER_ADDRESS="${entered:-$default}"
    valid_server "$SERVER_ADDRESS" || { err '请输入不带协议和端口的 IP 或域名。'; return 1; }
}

interactive_add() {
    local protocol="$1" count prefix sni='' private='' public='' sid='' credential pair name port tag i quota_input quota_bytes any_quota=0 confirm links export_file
    local -a quotas=() quota_labels=()
    ensure_dependencies && ( acquire_lock && ensure_singbox ) || return 1
    prompt_read '新增几条同协议节点？[1，最多20]：' count || return 1
    count="${count:-1}"
    [[ "$count" =~ ^([1-9]|1[0-9]|20)$ ]] || { err '数量需为 1–20。'; return 1; }
    prompt_read "节点显示名称（仅备注；多条时自动编号）[$protocol]：" prefix || return 1
    prefix="${prefix:-$protocol}"
    [[ ${#prefix} -le 70 && "$prefix" != *[[:cntrl:]]* && -n "${prefix//[[:space:]]/}" ]] || {
        err '名称需为 1–70 个字符，不能仅有空白或含控制字符。'; return 1;
    }
    ask_server || return 1
    if [[ "$protocol" == vless ]]; then
        prompt_read "Reality SNI（伪装域名，不是节点名称）[$DEFAULT_SNI]：" sni || return 1
        sni="${sni:-$DEFAULT_SNI}"
        valid_sni "$sni" || { err 'SNI 域名格式不正确。'; return 1; }
    fi
    port=$(find_free_port) || return 1
    prompt_read "第一条节点端口 [$port]：" FIRST_PORT || return 1
    port="${FIRST_PORT:-$port}"
    valid_port "$port" || { err '端口应为 1024–65535。'; return 1; }
    port_in_use "$port" && { err '此端口已经被配置或占用，请换端口。'; return 1; }
    for ((i=1; i<=count; i++)); do
        prompt_read "第 $i 条节点累计额度 GB [0=不限量，例100或0.5]：" quota_input || return 1
        quota_input="${quota_input:-0}"
        quota_bytes=$(quota_parse_gb "$quota_input") || return 1
        quotas+=("$quota_bytes")
        quota_labels+=("$quota_input")
        ((quota_bytes == 0)) || any_quota=1
    done
    printf '\n创建前核对（名称只用于备注，不参与连接认证）\n名称：%s\n协议：%s\n连接地址：%s\n首个端口：%s\n数量：%s\n' "$prefix" "$protocol" "$SERVER_ADDRESS" "$port" "$count"
    [[ "$protocol" != vless ]] || printf 'Reality SNI：%s\n' "$sni"
    for ((i=1; i<=count; i++)); do
        printf '第 %s 条累计额度：%s GB（0 表示不限量）\n' "$i" "${quota_labels[i-1]}"
    done
    prompt_read '确认创建以上节点？[Y/n]：' confirm || return 1
    case "${confirm,,}" in ''|y|yes) ;; *) ok '已取消，未新增节点。'; return 0 ;; esac
    ensure_service || return 1
    if ((any_quota)) || quota_enabled; then quota_enable_runtime || return 1; fi
    export_file=$(mktemp "$STATE_DIR/created-links-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || return 1
    chmod 600 "$export_file" || { rm -f -- "$export_file"; return 1; }
    ok "本批链接自动保存位置（仅 root 可读）：$export_file"
    for ((i=1; i<=count; i++)); do
        if ((i == 1)); then name="$prefix"; else
            port=$(find_free_port "$((port + 1))") || return 1
            name="${prefix}-${i}"
        fi
        if [[ "$protocol" == shadowsocks ]]; then credential=$(random_hex 18) || return 1
        else credential=$(new_uuid) || return 1; fi
        if [[ "$protocol" == vless ]]; then
            pair=$("$SB_BIN" generate reality-keypair) || { err '生成 Reality 密钥失败。'; return 1; }
            private=$(awk '/PrivateKey/{print $NF; exit}' <<<"$pair")
            public=$(awk '/PublicKey/{print $NF; exit}' <<<"$pair")
            sid=$(random_hex 8) || return 1
        fi
        if ! tag=$(add_node_data "$protocol" "$name" "$SERVER_ADDRESS" "$port" "$credential" "$sni" "$private" "$public" "$sid" "${quotas[i-1]}"); then
            warn "第 $i 条创建失败；前面已成功创建的 $((i-1)) 条节点保留，已导出链接不丢失。"
            return 1
        fi
        ok "已创建：$name｜$protocol｜$SERVER_ADDRESS:$port"
        if links=$(generate_links "$tag"); then
            printf '\n----- %s：复制下方完整链接 -----\n%s\n\n' "$name" "$links"
            printf '%s\n' "$links" >> "$export_file" || warn '链接已显示，但保存到导出文件失败。'
        else
            warn '节点已创建，但链接生成失败；请在“导出节点链接”中重试，不要重复创建。'
        fi
    done
    install_local_shortcut || warn '节点已创建，但 menu 入口未安装成功。'
    warn '创建成功不代表外网连通已验证。请在服务器提供商安全组及已有防火墙中放行上述端口。'
}

interactive_show_link() {
    local default metadata links
    ensure_dependencies || return 1
    choose_node || return 1
    metadata=$(read_metadata) || return 1
    default=$(jq -r --arg tag "$SELECTED_TAG" '.nodes[$tag].server // empty' <<<"$metadata")
    ask_server "$default" || return 1
    links=$(generate_links "$SELECTED_TAG" "$SERVER_ADDRESS") || return 1
    printf '\n复制下方完整链接：\n%s\n\n' "$links"
}

interactive_port() {
    local port
    ensure_dependencies || return 1
    choose_node && require_managed_node "$SELECTED_TAG" && ensure_singbox && ensure_service || return 1
    prompt_read '新的独立端口（1024–65535）：' port || return 1
    if quota_enabled; then quota_enable_runtime || return 1; fi
    update_node_port "$SELECTED_TAG" "$port" || return 1
    ok '仅该节点的端口已修改；请重新导入它的链接。'
}

interactive_rotate() {
    local confirm config protocol credential
    ensure_dependencies || return 1
    choose_node && require_managed_node "$SELECTED_TAG" && ensure_singbox && ensure_service || return 1
    prompt_read '重新生成该节点凭据会使它的旧链接失效，输入 YES 继续：' confirm || return 1
    [[ "$confirm" == YES ]] || { ok '已取消。'; return 0; }
    config=$(read_current_config) || return 1
    protocol=$(jq -r --arg tag "$SELECTED_TAG" '.inbounds[] | select(.tag == $tag) | .type' <<<"$config")
    if [[ "$protocol" == shadowsocks ]]; then credential=$(random_hex 18); else credential=$(new_uuid); fi || return 1
    if quota_enabled; then quota_enable_runtime || return 1; fi
    rotate_node_credential "$SELECTED_TAG" "$credential" || return 1
    ok '已重新生成选中节点的凭据；其他节点的凭据不变。'
}

interactive_delete() {
    local confirm
    ensure_dependencies || return 1
    choose_node && require_managed_node "$SELECTED_TAG" && ensure_singbox && ensure_service || return 1
    prompt_read "删除选中节点 $SELECTED_TAG？输入 DELETE 确认：" confirm || return 1
    [[ "$confirm" == DELETE ]] || { ok '已取消。'; return 0; }
    if quota_enabled; then quota_enable_runtime || return 1; fi
    delete_node_data "$SELECTED_TAG" || return 1
    ok '选中节点已删除，完整配置备份保留。'
}

show_service_status() {
    local backend
    backend=$(service_backend) || return 1
    if [[ "$backend" == systemd ]]; then systemctl --no-pager --full status sing-box.service
    else rc-service sing-box status; fi
}

manual_validate_restart() {
    ensure_dependencies && ensure_singbox && ensure_service || return 1
    [[ -f "$CONFIG_FILE" ]] || { err '尚无配置，请先新增节点。'; return 1; }
    if quota_enabled; then quota_enable_runtime || return 1; fi
    ( acquire_lock && validate_config "$CONFIG_FILE" && quota_sync && svc_restart )
}

interactive_quota_show() {
    ensure_dependencies || return 1
    quota_enable_runtime && quota_show_usage
}

interactive_quota_limit() {
    local input bytes
    ensure_dependencies && choose_node && require_managed_node "$SELECTED_TAG" || return 1
    prompt_read '该节点累计额度 GB（上传＋下载，0=不限量）：' input || return 1
    bytes=$(quota_parse_gb "$input") || return 1
    quota_enable_runtime && quota_set_limit "$SELECTED_TAG" "$bytes"
}

interactive_quota_reset() {
    local confirm
    ensure_dependencies && choose_node && require_managed_node "$SELECTED_TAG" || return 1
    prompt_read '只清零该节点累计用量并恢复额度，输入 RESET 确认：' confirm || return 1
    [[ "$confirm" == RESET ]] || { ok '已取消。'; return 0; }
    quota_enable_runtime && quota_reset_usage "$SELECTED_TAG"
}

add_node_menu() {
    local option
    while true; do
        printf '\n%s\n' '新增节点（每次支持 1–20 条）' \
          '1) VLESS + TCP + Reality（默认）' \
          '2) VMess + WebSocket' \
          '3) Shadowsocks' \
          '0) 返回主菜单'
        prompt_read '请选择协议 [1]：' option || return 0
        case "${option:-1}" in
            1) interactive_add vless || warn '本次操作未完成。'; return 0 ;;
            2) interactive_add vmess || warn '本次操作未完成。'; return 0 ;;
            3) interactive_add shadowsocks || warn '本次操作未完成。'; return 0 ;;
            0) return 0 ;;
            *) warn '请输入菜单中的编号。' ;;
        esac
    done
}

node_management_menu() {
    local option
    while true; do
        printf '\n%s\n' '节点管理' \
          '1) 修改节点端口' \
          '2) 重新生成 UUID / 密码' \
          '3) 删除节点' \
          '0) 返回主菜单'
        prompt_read '请选择 [0–3]：' option || return 0
        case "$option" in
            1) interactive_port || warn '端口未修改。' ;;
            2) interactive_rotate || warn '凭据未修改。' ;;
            3) interactive_delete || warn '节点未删除。' ;;
            0) return 0 ;;
            *) warn '请输入菜单中的编号。' ;;
        esac
    done
}

quota_menu() {
    local option
    while true; do
        printf '\n%s\n' '流量管理' \
          '1) 启用流量管理 / 查看额度和用量' \
          '2) 修改节点累计额度（保留已用量）' \
          '3) 手动清零节点用量并恢复额度' \
          '0) 返回主菜单'
        prompt_read '请选择 [0–3]：' option || return 0
        case "$option" in
            1) interactive_quota_show || warn '流量管理未就绪。' ;;
            2) interactive_quota_limit || warn '额度未成功修改。' ;;
            3) interactive_quota_reset || warn '清零未成功完成。' ;;
            0) return 0 ;;
            *) warn '请输入菜单中的编号。' ;;
        esac
    done
}

service_menu() {
    local option
    while true; do
        printf '\n%s\n' '服务与工具' \
          '1) 查看服务状态' \
          '2) 检查配置并重启服务' \
          '3) 安装 / 更新快捷命令 menu' \
          '0) 返回主菜单'
        prompt_read '请选择 [0–3]：' option || return 0
        case "$option" in
            1) show_service_status || warn '无法读取服务状态。' ;;
            2) manual_validate_restart || warn '检查或重启未成功。' ;;
            3) install_local_shortcut || warn '本地快捷命令未安装。' ;;
            0) return 0 ;;
            *) warn '请输入菜单中的编号。' ;;
        esac
    done
}

main_menu() {
    local option
    while true; do
        printf '\n========== 独立节点管理 v%s ==========\n' "$MANAGER_VERSION"
        printf '%s\n' \
          '1) 新增节点（完成后自动显示链接）' \
          '2) 查看全部节点' \
          '3) 导出节点链接' \
          '4) 节点管理' \
          '5) 流量管理' \
          '6) 服务与工具' \
          '0) 退出'
        prompt_read '请选择 [0–6]：' option || return 0
        case "$option" in
            1) add_node_menu ;;
            2) ensure_dependencies && list_nodes || warn '无法读取节点列表。' ;;
            3) interactive_show_link || warn '未导出节点。' ;;
            4) node_management_menu ;;
            5) quota_menu ;;
            6) service_menu ;;
            0) return 0 ;;
            *) warn '请输入菜单中的编号。' ;;
        esac
    done
}

main() {
    set -uo pipefail
    case "${1:-}" in
        --version) printf '%s\n' "$MANAGER_VERSION"; return 0 ;;
        --help|-h)
            printf '%s\n' '用法：bash proxy-node-manager.sh' \
              '每条新增节点使用独立端口及凭据；保留原有配置。' \
              '首次安装可用 PROXY_SINGBOX_VERSION=1.14.4 固定官方版本。' \
              '配置 /etc/sing-box/config.json；名称记录 /etc/sing-box/node-manager/nodes.json。' \
              '已安装的 sing-box 不会自动升级；原始分片 conf 只保留，不重新合并。' \
              '流量管理：systemd + nftables；累计上传＋下载，手动清零；1GB=1000000000字节。' \
              '本地入口 menu；内部服务参数 --quota-restore / --quota-daemon。'
            return 0 ;;
        ''|--quota-restore|--quota-daemon) ;;
        *) err '未知参数，使用 --help 查看用法。'; return 1 ;;
    esac
    [[ "$(uname -s)" == Linux ]] || { err '本脚本用于 Linux 服务器。'; return 1; }
    [[ "$(id -u)" == 0 ]] || { err '请以 root 身份运行。'; return 1; }
    if [[ ! -x "$SB_BIN" ]] && command -v sing-box >/dev/null; then
        SB_BIN=$(command -v sing-box)
    fi
    case "${1:-}" in
        --quota-restore) quota_restore; return $? ;;
        --quota-daemon) quota_daemon; return $? ;;
    esac
    install_local_shortcut || { err 'menu 入口安装未完成，停止本次启动。'; return 1; }
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
PROXY_MANAGER_EMBEDDED_V221_6a559016113994e6b289690b
bash "$manager_temp/proxy-node-manager.sh" "$@"
exit $?
