#!/usr/bin/env bash
# =============================================================================
#  colab_sunshine_tailscale.sh
#  Google Colab: XFCE4 + Xorg(dummy) / Xvfb + Tailscale(userspace) + Sunshine
#  - Không cần /dev/net/tun  (tailscaled --tun=userspace-networking)
#  - Không cần /dev/uinput   (Sunshine v0.23.1: fallback input qua XTest)
#  - Nhập PIN ghép Moonlight ngay trong Colab, KHÔNG cần mở web UI
#
#  CÁCH DÙNG TRONG COLAB (dùng dấu "!" – KHÔNG dùng %%bash vì %%bash không có stdin):
#     !bash colab_sunshine_tailscale.sh                # cài + chạy + chờ nhập PIN
#     !TS_AUTHKEY=tskey-auth-xxxx bash colab_sunshine_tailscale.sh
#     !bash colab_sunshine_tailscale.sh pin 1234       # chỉ gửi PIN
#     !bash colab_sunshine_tailscale.sh pin            # hỏi PIN rồi gửi
#     !bash colab_sunshine_tailscale.sh status         # xem trạng thái
#     !bash colab_sunshine_tailscale.sh logs           # xem log sunshine
#     !bash colab_sunshine_tailscale.sh keepalive      # chỉ giữ cell sống + auto-restart
#     !bash colab_sunshine_tailscale.sh tune           # ghi lại config low-latency + restart Sunshine
#     !bash colab_sunshine_tailscale.sh netcheck       # xem Moonlight đi direct hay qua relay DERP
#     !bash colab_sunshine_tailscale.sh gpucheck       # xác nhận NVENC (GPU) có thật sự đang encode
#     !bash colab_sunshine_tailscale.sh apps           # cài/cài lại Chrome + Steam, cập nhật apps.json
#
#  ỨNG DỤNG: mặc định cài Chrome + Steam (INSTALL_CHROME=0 / INSTALL_STEAM=0 để bỏ).
#    - Chrome chạy dưới root với --no-sandbox (wrapper chrome-colab).
#    - Steam không chạy được dưới root -> chạy dưới user 'gamer' (wrapper steam-colab).
#      Xvfb/Xorg-dummy KHÔNG có DRI -> Steam client & game 2D/nhẹ chạy được, game 3D nặng KHÔNG.
#
#  GPU: chọn Runtime -> Change runtime type -> T4 GPU TRƯỚC khi chạy. Script tự dò driver ở
#       /usr/lib64-nvidia (đặc thù Colab) và chuyển encoder = nvenc. CPU runtime -> x264, sẽ lag.
#     !bash colab_sunshine_tailscale.sh restart        # dọn Sunshine/XFCE/X rồi dựng lại (giữ Tailscale)
#     !bash colab_sunshine_tailscale.sh stop           # chỉ dọn desktop stack
#
#  QUY TẮC: KHÔNG chạy 'tune'/'restart' ở cell khác khi cell setup đang keep-alive
#           mà chưa Stop cell đó trước (script có khoá chống tranh chấp, nhưng an toàn nhất
#           là: Stop cell 1 -> chạy 'restart' -> để cell đó keep-alive).
#
#  GIẢM LAG CHUỘT: SW_PRESET=ultrafast (mặc định) | superfast | veryfast
#                  SUNSHINE_ENCODER=nvenc nếu Colab GPU (script tự dò)
#
#  LƯU Ý: sau khi ghép PIN xong script KHÔNG thoát mà giữ cell chạy (keep-alive).
#  Nếu cell thoát, Colab sẽ dọn tiến trình nền -> Moonlight mất kết nối.
#  Đặt KEEP_ALIVE=0 nếu muốn script thoát ngay (không khuyến nghị).
#
#  BIẾN MÔI TRƯỜNG (tuỳ chọn):
#     TS_AUTHKEY        auth key Tailscale (nếu không có sẽ in link login)
#     TS_HOSTNAME       tên máy trên tailnet         (mặc định: colab-sunshine)
#     SUN_USER/SUN_PASS user/pass API Sunshine        (mặc định: colab / colab1234)
#     SCREEN_RES        độ phân giải màn hình ảo      (mặc định: 1920x1080)
#     SUNSHINE_ENCODER  software | nvenc | auto       (mặc định: auto)
#     SUNSHINE_PIN      PIN gửi tự động nếu đặt sẵn
# =============================================================================
set -o pipefail

# ----------------------------- cấu hình ------------------------------------
export DEBIAN_FRONTEND=noninteractive
export DISPLAY=":10"
export HOME="${HOME:-/root}"

TS_HOSTNAME="${TS_HOSTNAME:-colab-sunshine}"
SUN_USER="${SUN_USER:-colab}"
SUN_PASS="${SUN_PASS:-colab1234}"
SCREEN_RES="${SCREEN_RES:-1920x1080}"
SUNSHINE_ENCODER="${SUNSHINE_ENCODER:-auto}"
SUNSHINE_VER="v0.23.1"          # bản cuối còn fallback XTest (không cần uinput)

WORK=/opt/colab-sunshine
LOG=$WORK/logs
SUN_CONF_DIR=$HOME/.config/sunshine
SUN_CONF=$SUN_CONF_DIR/sunshine.conf
SUN_API="https://localhost:47990"
mkdir -p "$WORK" "$LOG" "$SUN_CONF_DIR"

c_ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
c_info() { printf '\033[1;34m[..]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[1;31m[XX]\033[0m %s\n' "$*"; }

is_running() { pgrep -x "$1" >/dev/null 2>&1; }

# Chạy tiến trình nền TÁCH HẲN khỏi process group của cell Colab.
# (nohup & thôi chưa đủ: khi cell/script kết thúc Colab dọn cả process group
#  -> Sunshine/Tailscale bị kill -> Moonlight ghép xong nhưng không kết nối được)
#   daemon <logfile> <cmd...>
daemon() {
  local logfile="$1"; shift
  setsid nohup "$@" >"$logfile" 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# ----------------------------- 1. gói apt ----------------------------------
install_packages() {
  c_info "Cài gói apt (Xorg dummy, Xvfb, XFCE4, PulseAudio, tools)..."
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl wget jq gnupg lsb-release procps psmisc iproute2 software-properties-common x11-xserver-utils \
    xserver-xorg-core xserver-xorg-video-dummy xvfb \
    x11-xserver-utils x11-utils xdotool dbus-x11 xauth \
    xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings \
    xfce4-terminal thunar mousepad xfce4-appfinder \
    fonts-dejavu-core xfonts-base \
    pulseaudio pulseaudio-utils \
    libxtst6 libxrandr2 libxfixes3 libxcb-shm0 libxcb-xfixes0 \
    >/dev/null
  c_ok "Đã cài gói apt."
}

# ----------------------------- 2. màn hình ảo ------------------------------
write_xorg_conf() {
  local W=${SCREEN_RES%x*} H=${SCREEN_RES#*x}
  cat > "$WORK/xorg-dummy.conf" <<EOF
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "AutoAddDevices" "false"
    Option "AutoEnableDevices" "false"
    Option "AllowEmptyInput" "true"
EndSection
Section "Device"
    Identifier "dummy_dev"
    Driver "dummy"
    VideoRam 512000
EndSection
Section "Monitor"
    Identifier "dummy_mon"
    HorizSync 5.0 - 1000.0
    VertRefresh 5.0 - 200.0
    Modeline "${W}x${H}_60" 173.00 ${W} $((W+128)) $((W+328)) $((W+656)) ${H} $((H+3)) $((H+8)) $((H+40)) -hsync +vsync
EndSection
Section "Screen"
    Identifier "dummy_scr"
    Device "dummy_dev"
    Monitor "dummy_mon"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "${W}x${H}_60"
        Virtual ${W} ${H}
    EndSubSection
EndSection
Section "ServerLayout"
    Identifier "layout"
    Screen "dummy_scr"
EndSection
EOF
}

x_is_up() { xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; }

start_display() {
  if x_is_up; then c_ok "X server $DISPLAY đã chạy."; return; fi
  write_xorg_conf
  c_info "Khởi động Xorg (driver dummy) trên $DISPLAY ..."
  daemon "$LOG/xorg.out" Xorg "$DISPLAY" -config "$WORK/xorg-dummy.conf" \
       -noreset -nolisten tcp -novtswitch -sharevts \
       +extension XTEST +extension RANDR +extension GLX \
       -logfile "$LOG/xorg.log"
  for _ in $(seq 1 15); do x_is_up && break; sleep 1; done

  if x_is_up; then
    c_ok "Xorg dummy đang chạy trên $DISPLAY."
  else
    c_warn "Xorg dummy không lên (container không có VT). Chuyển sang Xvfb..."
    pkill -f "Xorg $DISPLAY" 2>/dev/null
    daemon "$LOG/xvfb.log" Xvfb "$DISPLAY" -screen 0 "${SCREEN_RES}x24" -nolisten tcp \
         +extension XTEST +extension RANDR +extension GLX
    for _ in $(seq 1 15); do x_is_up && break; sleep 1; done
    x_is_up && c_ok "Xvfb đang chạy trên $DISPLAY." || { c_err "Không khởi động được X server!"; exit 1; }
  fi
  xdpyinfo -display "$DISPLAY" | grep -q XTEST && c_ok "Extension XTEST sẵn sàng (Sunshine sẽ dùng cho chuột/phím)." \
                                              || c_warn "Không thấy XTEST trong xdpyinfo!"
}

# ----------------------------- 3. âm thanh ---------------------------------
start_audio() {
  if pactl info >/dev/null 2>&1; then c_ok "PulseAudio đã chạy."; return; fi
  c_info "Khởi động PulseAudio (null sink)..."
  pulseaudio -D --exit-idle-time=-1 --disallow-exit --log-target=file:"$LOG/pulse.log" 2>/dev/null || true
  sleep 1
  pactl load-module module-null-sink sink_name=colab_sink sink_properties=device.description=ColabSink >/dev/null 2>&1 || true
  pactl set-default-sink colab_sink >/dev/null 2>&1 || true
  pactl info >/dev/null 2>&1 && c_ok "PulseAudio OK." || c_warn "PulseAudio không chạy (stream vẫn hoạt động, chỉ mất tiếng)."
}

# ----------------------------- 4. XFCE4 ------------------------------------
start_xfce() {
  if pgrep -x xfce4-session >/dev/null; then c_ok "XFCE4 đã chạy."; return; fi
  c_info "Khởi động XFCE4..."
  # tắt screensaver/lock, tránh popup
  export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
  daemon "$LOG/xfce.log" dbus-launch --exit-with-session startxfce4
  for _ in $(seq 1 20); do pgrep -x xfce4-panel >/dev/null && break; sleep 1; done
  xset -display "$DISPLAY" s off -dpms 2>/dev/null || true
  pgrep -x xfce4-session >/dev/null && c_ok "XFCE4 đang chạy." || c_warn "XFCE4 chưa lên đầy đủ, xem $LOG/xfce.log"
}

# ----------------------------- 5. Tailscale --------------------------------
install_tailscale() {
  if command -v tailscale >/dev/null; then c_ok "Tailscale đã cài."; return; fi
  c_info "Cài Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
  command -v tailscale >/dev/null && c_ok "Đã cài Tailscale." || { c_err "Cài Tailscale thất bại."; exit 1; }
}

start_tailscale() {
  mkdir -p /var/lib/tailscale /run/tailscale
  if ! is_running tailscaled; then
    c_info "Khởi động tailscaled (userspace-networking, không cần /dev/net/tun)..."
    daemon "$LOG/tailscaled.log" tailscaled --tun=userspace-networking \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/run/tailscale/tailscaled.sock \
        --port=41641
    sleep 3
  fi

  if tailscale ip -4 >/dev/null 2>&1; then
    c_ok "Tailscale đã đăng nhập: $(tailscale ip -4)"; return
  fi

  local UP_ARGS=(--hostname="$TS_HOSTNAME" --accept-dns=false --reset)
  if [ -n "$TS_AUTHKEY" ]; then
    c_info "tailscale up với auth key..."
    tailscale up "${UP_ARGS[@]}" --authkey="$TS_AUTHKEY" >"$LOG/tailscale-up.log" 2>&1
  else
    c_info "tailscale up (không có TS_AUTHKEY) -> chờ bạn bấm link đăng nhập..."
    : > "$LOG/tailscale-up.log"
    daemon "$LOG/tailscale-up.log" tailscale up "${UP_ARGS[@]}"
    local shown=""
    for _ in $(seq 1 300); do   # tối đa 5 phút
      if tailscale ip -4 >/dev/null 2>&1; then break; fi
      local url; url=$(grep -o 'https://login.tailscale.com/[A-Za-z0-9/_-]*' "$LOG/tailscale-up.log" | head -1)
      if [ -n "$url" ] && [ "$url" != "$shown" ]; then
        echo; echo "  =====================================================";
        echo "   MỞ LINK NÀY ĐỂ ĐĂNG NHẬP TAILSCALE:"; echo "   $url";
        echo "  ====================================================="; echo
        shown=$url
      fi
      sleep 1
    done
  fi
  tailscale ip -4 >/dev/null 2>&1 && c_ok "Tailscale IP: $(tailscale ip -4)" \
                                   || { c_err "Tailscale chưa đăng nhập. Xem $LOG/tailscale-up.log"; exit 1; }
}

# ----------------------------- 6. Sunshine ---------------------------------
install_sunshine() {
  if command -v sunshine >/dev/null; then c_ok "Sunshine đã cài: $(sunshine --version 2>/dev/null | head -1)"; return; fi
  local os_id ver deb
  os_id=$(. /etc/os-release; echo "${ID}")
  ver=$(. /etc/os-release; echo "${VERSION_ID}")
  # Colab = Ubuntu 22.04; Kaggle có thể là Ubuntu hoặc Debian tuỳ image -> chọn deb tương ứng
  case "$os_id:$ver" in
    ubuntu:24.*)  deb="sunshine-ubuntu-24.04-amd64.deb" ;;
    ubuntu:*)     deb="sunshine-ubuntu-22.04-amd64.deb" ;;
    debian:12*)   deb="sunshine-debian-bookworm-amd64.deb" ;;
    debian:11*)   deb="sunshine-debian-bullseye-amd64.deb" ;;
    debian:*)     deb="sunshine-debian-bookworm-amd64.deb" ;;
    *)            deb="sunshine-ubuntu-22.04-amd64.deb"; c_warn "OS lạ ($os_id $ver), thử deb Ubuntu 22.04" ;;
  esac
  c_info "OS: $os_id $ver"
  c_info "Tải Sunshine $SUNSHINE_VER ($deb) – bản còn hỗ trợ XTest fallback..."
  wget -q -O "$WORK/sunshine.deb" "https://github.com/LizardByte/Sunshine/releases/download/${SUNSHINE_VER}/${deb}" \
    || { c_err "Tải Sunshine thất bại."; exit 1; }
  apt-get install -y -qq "$WORK/sunshine.deb" >/dev/null 2>&1 || apt-get install -y -qq -f >/dev/null
  command -v sunshine >/dev/null && c_ok "Đã cài Sunshine." || { c_err "Cài Sunshine thất bại."; exit 1; }
}

# --- GPU / NVENC ------------------------------------------------------------
# Colab GPU runtime để driver ở /usr/lib64-nvidia (KHÔNG có trong ldconfig mặc định),
# nên phải: (1) quét thư mục đó, (2) đăng ký vào ldconfig + LD_LIBRARY_PATH để Sunshine
# nạp được libnvidia-encode / libcuda. Nếu không, Sunshine sẽ rơi về software.
NV_DIRS="/usr/lib64-nvidia /usr/local/nvidia/lib64 /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/local/cuda/lib64"

nv_find_lib() {   # nv_find_lib libnvidia-encode.so
  local d; for d in $NV_DIRS; do ls "$d"/"$1"* >/dev/null 2>&1 && { echo "$d"; return 0; }; done
  ldconfig -p 2>/dev/null | grep -q "$1" && { echo "ldconfig"; return 0; }
  return 1
}

gpu_available() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }

setup_gpu_libs() {
  gpu_available || return 1
  local enc_dir cuda_dir
  enc_dir=$(nv_find_lib libnvidia-encode.so) || return 1
  cuda_dir=$(nv_find_lib libcuda.so) || return 1
  # đăng ký thư mục driver vào ldconfig (idempotent)
  {
    for d in $NV_DIRS; do [ -d "$d" ] && echo "$d"; done
  } > /etc/ld.so.conf.d/zz-colab-nvidia.conf
  ldconfig 2>/dev/null
  export LD_LIBRARY_PATH="/usr/lib64-nvidia:/usr/local/nvidia/lib64:/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=all
  c_ok "GPU: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1) | libnvidia-encode: $enc_dir | libcuda: $cuda_dir"
  return 0
}

pick_encoder() {
  if [ "$SUNSHINE_ENCODER" != "auto" ]; then echo "$SUNSHINE_ENCODER"; return; fi
  if setup_gpu_libs >/dev/null 2>&1; then echo nvenc; else echo software; fi
}

gpu_check() {
  echo "----- KIỂM TRA GPU / NVENC -----"
  if ! gpu_available; then
    echo "Không có GPU (Runtime -> Change runtime type -> T4 GPU). Đang dùng CPU encode."; return
  fi
  nvidia-smi --query-gpu=name,driver_version,utilization.gpu,utilization.encoder,memory.used --format=csv 2>/dev/null
  echo
  echo "libnvidia-encode : $(nv_find_lib libnvidia-encode.so || echo 'KHÔNG THẤY')"
  echo "libcuda          : $(nv_find_lib libcuda.so || echo 'KHÔNG THẤY')"
  echo "Sunshine encoder : $(grep '^encoder' "$SUN_CONF" 2>/dev/null | awk '{print $3}')"
  echo "Sunshine LD_LIBRARY_PATH: $(tr '\0' '\n' < /proc/$(pgrep -x sunshine | head -1)/environ 2>/dev/null | grep ^LD_LIBRARY_PATH | cut -d= -f2-)"
  echo
  echo "Log Sunshine liên quan encoder (mới nhất):"
  grep -iE "nvenc|cuda|encoder|software" "$LOG/sunshine.log" 2>/dev/null | tail -n 12 | sed 's/^/   /'
  echo
  echo "-> Đang stream mà 'utilization.encoder' > 0 % = NVENC đang chạy thật."
  echo "-> Thấy 'Found H.264 encoder: h264_nvenc' = OK; thấy 'libx264' = vẫn CPU."
}

# Số thread encoder phần mềm = số vCPU (Colab thường 2, GPU runtime 2-8)
sw_threads() { local n; n=$(nproc 2>/dev/null || echo 2); (( n < 2 )) && n=2; (( n > 8 )) && n=8; echo "$n"; }

write_sunshine_conf() {
  local enc; enc=$(pick_encoder)
  local preset="${SW_PRESET:-ultrafast}"     # ultrafast < superfast < veryfast (chậm hơn = nét hơn)
  local threads; threads=$(sw_threads)
  cat > "$SUN_CONF" <<EOF
# --- sinh tự động bởi colab_sunshine_tailscale.sh (profile: low-latency) ---
capture = x11
encoder = ${enc}

# ---- phần mềm (x264) : ưu tiên độ trễ ----
sw_preset = ${preset}
sw_tune = zerolatency
min_threads = ${threads}

# ---- NVENC (chỉ dùng khi encoder = nvenc; Linux) ----
nvenc_preset = 1
nvenc_twopass = disabled
nvenc_vbv_increase = 0

# ---- chung ----
min_log_level = info
upnp = off
origin_web_ui_allowed = pc
port = 47989
# 720p đặt trước để Moonlight mặc định chọn (encode 1080p bằng CPU Colab quá nặng)
fps = [30,60]
resolutions = [
    1280x720,
    1600x900,
    1920x1080
]
file_apps = ${SUN_CONF_DIR}/apps.json
EOF
  # apps.json: Desktop + Chrome + Steam (Big Picture). Steam/Chrome chạy qua wrapper
  # /usr/local/bin/{chrome-colab,steam-colab} (xem install_apps).
  cat > "$SUN_CONF_DIR/apps.json" <<'EOF'
{
  "env": { "PATH": "$(PATH):$(HOME)/.local/bin:/usr/local/bin" },
  "apps": [
    { "name": "Desktop", "image-path": "desktop.png" },
    { "name": "Chrome",
      "detached": [ "/usr/local/bin/chrome-colab" ],
      "image-path": "desktop.png" },
    { "name": "Steam Big Picture",
      "detached": [ "/usr/local/bin/steam-colab -bigpicture" ],
      "image-path": "steam.png" }
  ]
}
EOF
  c_ok "Ghi cấu hình Sunshine (encoder=${enc}, preset=${preset}, threads=${threads}, capture=x11)."
}

# =============================================================================
#  ỨNG DỤNG: Google Chrome + Steam
#  - Chrome: chạy dưới root cần --no-sandbox; tắt GPU sandbox vì Xvfb/dummy không có DRI.
#  - Steam : TỪ CHỐI chạy dưới root -> tạo user 'gamer', cấp quyền X (xhost) + PulseAudio,
#            chạy qua 'su gamer'. Không có VT/DRM nên Steam chạy chế độ desktop/BigPicture
#            với render phần mềm; game 3D nặng sẽ không đủ (không có DRI trong Xvfb).
# =============================================================================
INSTALL_CHROME=${INSTALL_CHROME:-1}
INSTALL_STEAM=${INSTALL_STEAM:-1}
STEAM_USER=${STEAM_USER:-gamer}

install_chrome() {
  [ "$INSTALL_CHROME" = "1" ] || return 0
  if command -v google-chrome >/dev/null 2>&1; then c_ok "Chrome đã cài."; else
    c_info "Cài Google Chrome..."
    wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt-get install -y -qq /tmp/chrome.deb >/dev/null 2>&1 || apt-get install -y -qq -f >/dev/null 2>&1
    rm -f /tmp/chrome.deb
    command -v google-chrome >/dev/null 2>&1 || { c_warn "Cài Chrome thất bại (bỏ qua)."; return 0; }
  fi
  # wrapper dùng chung cho apps.json và menu XFCE
  cat > /usr/local/bin/chrome-colab <<'EOF'
#!/usr/bin/env bash
export DISPLAY=${DISPLAY:-:10}
exec google-chrome --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --no-first-run --no-default-browser-check --password-store=basic \
  --window-size=1920,1080 --start-maximized "$@"
EOF
  chmod +x /usr/local/bin/chrome-colab
  # sửa .desktop để bấm từ menu XFCE cũng chạy được dưới root
  if [ -f /usr/share/applications/google-chrome.desktop ]; then
    sed -i 's#^Exec=/usr/bin/google-chrome-stable#Exec=/usr/local/bin/chrome-colab#' /usr/share/applications/google-chrome.desktop
  fi
  c_ok "Chrome sẵn sàng: chrome-colab (--no-sandbox)."
}

install_steam() {
  [ "$INSTALL_STEAM" = "1" ] || return 0
  # user không phải root cho Steam
  if ! id "$STEAM_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G audio,video "$STEAM_USER"
    c_ok "Tạo user $STEAM_USER cho Steam."
  fi
  if command -v steam >/dev/null 2>&1; then c_ok "Steam đã cài."; else
    c_info "Cài Steam (multiverse + i386, ~400MB)..."
    local os_id; os_id=$(. /etc/os-release; echo "$ID")
    dpkg --add-architecture i386
    if [ "$os_id" = "ubuntu" ]; then
      add-apt-repository -y multiverse >/dev/null 2>&1 || true
      apt-get update -qq
      # steam-installer trên Ubuntu; fallback gói .deb chính thức của Valve
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq steam-installer >/dev/null 2>&1 \
        || { wget -qO /tmp/steam.deb https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb
             DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /tmp/steam.deb >/dev/null 2>&1; rm -f /tmp/steam.deb; }
    else
      sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
      sed -i 's/ main$/ main contrib non-free/' /etc/apt/sources.list 2>/dev/null || true
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq steam-installer >/dev/null 2>&1 || true
    fi
    # thư viện 32-bit + mesa để Steam client khởi động được (render phần mềm)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      libgl1-mesa-dri libgl1-mesa-dri:i386 libgl1:i386 libc6:i386 libstdc++6:i386 \
      libx11-6:i386 libxss1:i386 libfreetype6:i386 libnss3 libgbm1 libvulkan1 mesa-vulkan-drivers \
      xterm >/dev/null 2>&1 || true
    command -v steam >/dev/null 2>&1 || { c_warn "Cài Steam thất bại (bỏ qua)."; return 0; }
  fi
  # wrapper: chạy Steam dưới user gamer, dùng X :10 và PulseAudio của root
  cat > /usr/local/bin/steam-colab <<EOF
#!/usr/bin/env bash
export DISPLAY=\${DISPLAY:-:10}
# cho user $STEAM_USER truy cập X server + pulse của root
xhost +SI:localuser:$STEAM_USER >/dev/null 2>&1 || true
PULSE_SOCK=\$(ls /run/user/0/pulse/native /tmp/pulse-*/native 2>/dev/null | head -n1)
[ -n "\$PULSE_SOCK" ] && chmod 777 "\$(dirname "\$PULSE_SOCK")" "\$PULSE_SOCK" 2>/dev/null
exec su - $STEAM_USER -c "DISPLAY=\$DISPLAY PULSE_SERVER=unix:\$PULSE_SOCK \
  STEAM_RUNTIME=1 LIBGL_ALWAYS_SOFTWARE=1 STEAM_FRAME_FORCE_CLOSE=1 \
  steam -no-cef-sandbox \$*"
EOF
  chmod +x /usr/local/bin/steam-colab
  if [ -f /usr/share/applications/steam.desktop ]; then
    sed -i 's#^Exec=/usr/games/steam#Exec=/usr/local/bin/steam-colab#; s#^Exec=steam#Exec=/usr/local/bin/steam-colab#' /usr/share/applications/steam.desktop
  fi
  c_ok "Steam sẵn sàng: steam-colab (user $STEAM_USER). Lần đầu mở sẽ tải runtime ~300MB."
}

install_apps() { install_chrome; install_steam; }

# Chẩn đoán mạng: đi thẳng (direct) hay qua relay DERP -> ảnh hưởng lớn tới lag chuột
net_check() {
  echo "----- KIỂM TRA MẠNG TAILSCALE -----"
  local peers
  peers=$(tailscale status --json 2>/dev/null | jq -r '.Peer[]? | select(.Online==true) | "\(.HostName)\t\(.TailscaleIPs[0])\t\(.CurAddr // "relay:" + (.Relay // "?"))"')
  if [ -z "$peers" ]; then echo "Chưa có peer online (mở Moonlight, kết nối 1 lần rồi chạy lại)."; return; fi
  printf '%-22s %-16s %s\n' "PEER" "IP" "ĐƯỜNG ĐI"; echo "$peers" | awk -F'\t' '{printf "%-22s %-16s %s\n",$1,$2,$3}'
  echo
  echo "-> 'relay:xxx' = đi qua DERP (lag cao). 'ip:port' = direct (tốt)."
  echo "   Ping thử từng peer (10 gói):"
  echo "$peers" | awk -F'\t' '{print $2}' | while read -r ip; do
    tailscale ping -c 4 "$ip" 2>/dev/null | tail -n 1 | sed "s/^/   $ip: /"
  done
  echo "-----------------------------------"
  echo "CPU: $(nproc) vCPU | load: $(cut -d' ' -f1-3 /proc/loadavg) | Sunshine RSS: $(ps -o rss= -C sunshine 2>/dev/null | awk '{s+=$1} END{printf "%.0f MB", s/1024}')"
}

# Khoá tạm: khi đang tune/restart thì keep_alive KHÔNG được tự khởi động Sunshine
# (tránh 2 tiến trình cùng bind port 47989/47990 rồi chết cả hai)
TUNE_LOCK=$WORK/.tuning
lock_on()  { touch "$TUNE_LOCK"; }
lock_off() { rm -f "$TUNE_LOCK"; }

# Dừng hẳn Sunshine + chờ port 47990 được trả lại
stop_sunshine() {
  pkill -x sunshine 2>/dev/null
  for _ in $(seq 1 10); do
    is_running sunshine || ! ss -ltn 2>/dev/null | grep -q ':47990 ' && break
    sleep 1
  done
  pkill -9 -x sunshine 2>/dev/null; sleep 1
}

# Khởi động Sunshine và CHỜ API lên; nếu lỗi tự in log
launch_sunshine() {
  export DISPLAY
  setup_gpu_libs >/dev/null 2>&1 || true     # nạp LD_LIBRARY_PATH driver NVIDIA (nếu có GPU)
  daemon "$LOG/sunshine.log" sunshine "$SUN_CONF"
  for _ in $(seq 1 30); do
    if curl -sk -u "$SUN_USER:$SUN_PASS" "$SUN_API/api/config" >/dev/null 2>&1; then
      sleep 2
      # xác nhận encoder thật sự được chọn (Sunshine probe lúc khởi động)
      if grep -q "h264_nvenc" "$LOG/sunshine.log" 2>/dev/null; then
        c_ok "Encoder thực tế: NVENC (h264_nvenc) - GPU đang encode."
      elif grep -qi "libx264" "$LOG/sunshine.log" 2>/dev/null; then
        if [ "$(grep '^encoder' "$SUN_CONF" | awk '{print $3}')" = "nvenc" ]; then
          c_warn "Cấu hình nvenc nhưng Sunshine rơi về libx264 (CPU). Chạy: bash $0 gpucheck"
        else
          c_warn "Encoder thực tế: libx264 (CPU). Không thấy GPU/NVENC -> sẽ lag hơn."
        fi
      fi
      return 0
    fi
    sleep 1
  done
  c_err "Sunshine không lên. 40 dòng log cuối ($LOG/sunshine.log):"
  echo "------------------------------------------------------------"
  tail -n 40 "$LOG/sunshine.log" 2>/dev/null
  echo "------------------------------------------------------------"
  return 1
}

# Ghi lại cấu hình low-latency và khởi động lại Sunshine (không cần cài lại)
tune_restart() {
  if ! x_is_up; then c_err "X server $DISPLAY không chạy -> Sunshine không thể lên. Chạy lại setup."; return 1; fi
  lock_on
  write_sunshine_conf
  c_info "Khởi động lại Sunshine với cấu hình mới..."
  stop_sunshine
  if launch_sunshine; then
    c_ok "Sunshine đã chạy lại. Client Moonlight đã ghép vẫn giữ nguyên."
    sleep 2; grep -iE "encoder|nvenc|software|XTest|uinput" "$LOG/sunshine.log" | tail -n 6
  fi
  lock_off
}

# Dọn toàn bộ desktop stack (giữ Tailscale để không phải login lại)
stop_desktop() {
  c_info "Dọn tiến trình cũ (Sunshine, XFCE, X server, PulseAudio)..."
  lock_on
  stop_sunshine
  pkill -x xfce4-session 2>/dev/null; pkill -f startxfce4 2>/dev/null
  pkill -x xfce4-panel 2>/dev/null; pkill -x xfwm4 2>/dev/null; pkill -x xfdesktop 2>/dev/null
  pkill -x pulseaudio 2>/dev/null
  pkill -f "Xorg $DISPLAY" 2>/dev/null; pkill -f "Xvfb $DISPLAY" 2>/dev/null
  sleep 2
  rm -f "/tmp/.X${DISPLAY#:}-lock" "/tmp/.X11-unix/X${DISPLAY#:}" 2>/dev/null
  lock_off
  c_ok "Đã dọn."
}

# Trước khi setup: nếu X chết mà còn tiến trình con "mồ côi" -> dọn hết
preflight_cleanup() {
  if x_is_up; then return; fi
  if is_running sunshine || pgrep -x xfce4-session >/dev/null || pgrep -x pulseaudio >/dev/null \
     || [ -e "/tmp/.X${DISPLAY#:}-lock" ]; then
    c_warn "X server $DISPLAY đã chết nhưng còn tiến trình cũ -> dọn trước khi chạy lại."
    stop_desktop
  fi
}

start_sunshine() {
  if is_running sunshine && curl -sk -u "$SUN_USER:$SUN_PASS" "$SUN_API/api/config" >/dev/null 2>&1; then
    c_ok "Sunshine đã chạy."; return
  fi
  is_running sunshine && { c_warn "Sunshine đang chạy nhưng API không phản hồi -> khởi động lại."; stop_sunshine; }
  lock_on
  write_sunshine_conf
  # đặt user/pass cho API (không cần mở web UI để tạo tài khoản)
  sunshine --creds "$SUN_USER" "$SUN_PASS" >/dev/null 2>&1 || true
  c_info "Khởi động Sunshine..."
  if ! launch_sunshine; then lock_off; exit 1; fi
  lock_off
  c_ok "Sunshine API sẵn sàng (port 47990)."
  sleep 2
  if grep -qiE "Unable to create virtual (mouse|keyboard)|uinput" "$LOG/sunshine.log"; then
    c_ok "Không có /dev/uinput -> Sunshine dùng XTest cho chuột/phím (đúng như mong đợi)."
  fi
}

# ----------------------------- 7. PIN --------------------------------------
send_pin() {
  local pin="$1"
  [[ "$pin" =~ ^[0-9]{4}$ ]] || { c_err "PIN phải là 4 chữ số."; return 1; }
  local resp
  resp=$(curl -sk -u "$SUN_USER:$SUN_PASS" -H "Content-Type: application/json" \
          -X POST "$SUN_API/api/pin" -d "{\"pin\":\"$pin\",\"name\":\"Moonlight\"}")
  if echo "$resp" | grep -q '"status" *: *"\?true'; then
    c_ok "Ghép đôi THÀNH CÔNG. Mở Moonlight và chọn máy để stream."
    return 0
  else
    c_err "Ghép đôi thất bại. Phản hồi: $resp"
    c_warn "Hãy bấm 'Add PC' trong Moonlight TRƯỚC, rồi mới nhập PIN ở đây."
    return 1
  fi
}

pin_prompt_loop() {
  echo
  echo "================= NHẬP PIN GHÉP MOONLIGHT ================="
  echo " 1) Trên Moonlight: Add PC -> nhập IP Tailscale: $(tailscale ip -4 2>/dev/null)"
  echo " 2) Moonlight hiện PIN 4 số -> gõ vào ô dưới rồi Enter."
  echo "    (gõ q để thoát vòng nhập PIN; các dịch vụ vẫn chạy nền)"
  echo "==========================================================="
  if [ -n "$SUNSHINE_PIN" ]; then send_pin "$SUNSHINE_PIN" && return; fi
  while true; do
    printf 'PIN> '
    read -r pin || break
    [ "$pin" = "q" ] && break
    [ -z "$pin" ] && continue
    send_pin "$pin" && break
  done
}

# ----------------------------- status / logs -------------------------------
show_status() {
  echo "----- TRẠNG THÁI -----"
  x_is_up                 && echo "X server   : OK ($DISPLAY)"     || echo "X server   : KHÔNG chạy"
  pgrep -x xfce4-session >/dev/null && echo "XFCE4      : OK" || echo "XFCE4      : KHÔNG chạy"
  is_running tailscaled   && echo "tailscaled : OK ($(tailscale ip -4 2>/dev/null || echo 'chưa login'))" || echo "tailscaled : KHÔNG chạy"
  is_running sunshine     && echo "Sunshine   : OK (encoder=$(grep '^encoder' "$SUN_CONF" 2>/dev/null | awk '{print $3}'))" || echo "Sunshine   : KHÔNG chạy"
  echo "Paired clients:"
  curl -sk -u "$SUN_USER:$SUN_PASS" "$SUN_API/api/clients/list" 2>/dev/null | jq -r '.named_certs[]?.name // empty' 2>/dev/null | sed 's/^/  - /'
  echo "Logs: $LOG"
}

# ----------------------------- keep-alive ----------------------------------
# Giữ cell Colab chạy để runtime không idle-timeout và các dịch vụ không bị dọn.
# Tự khởi động lại Sunshine / tailscaled nếu chết. Ctrl+C / Stop cell = thoát
# (dịch vụ vẫn chạy nền nhờ setsid, nhưng Colab có thể dọn sau vài phút).
keep_alive() {
  echo
  c_ok "Đang giữ cell chạy để duy trì stream. (Stop cell để thoát; KEEP_ALIVE=0 để tắt)"
  echo "   Muốn ghép thêm máy khác: mở cell mới -> !bash $0 pin 1234"
  local i=0
  while true; do
    sleep 30; i=$((i+1))
    # đang tune/restart ở cell khác -> không can thiệp
    [ -e "$TUNE_LOCK" ] && continue
    if ! is_running sunshine; then
      c_warn "Sunshine đã dừng -> khởi động lại..."
      launch_sunshine || true
    fi
    if ! is_running tailscaled; then
      c_warn "tailscaled đã dừng -> khởi động lại..."
      start_tailscale
    fi
    if ! x_is_up; then c_err "X server đã chết! Chạy lại script."; break; fi
    # mỗi 10 phút in 1 dòng để log không im lặng quá lâu
    (( i % 20 == 0 )) && printf '[%s] alive - TS %s - sunshine %s\n' \
        "$(date +%H:%M:%S)" "$(tailscale ip -4 2>/dev/null)" "$(is_running sunshine && echo OK || echo DOWN)"
  done
}

# ----------------------------- main ----------------------------------------
case "${1:-setup}" in
  pin)
    if [ -n "$2" ]; then send_pin "$2"; else pin_prompt_loop; fi ;;
  status) show_status ;;
  logs)   tail -n 60 "$LOG/sunshine.log" ;;
  keepalive) keep_alive ;;
  tune)     tune_restart ;;
  netcheck) net_check ;;
  gpucheck) gpu_check ;;
  apps)     install_apps; write_sunshine_conf; tune_restart ;;
  stop)     stop_desktop ;;
  restart)  # dọn desktop stack rồi dựng lại (Tailscale giữ nguyên, không cần login lại)
    stop_desktop
    exec env KEEP_ALIVE="${KEEP_ALIVE:-1}" bash "$0" setup ;;
  setup|*)
    [ "$(id -u)" -eq 0 ] || { c_err "Cần chạy với root (Colab mặc định là root)."; exit 1; }
    rm -f "$TUNE_LOCK"
    install_packages
    preflight_cleanup
    start_display
    start_audio
    start_xfce
    install_tailscale
    start_tailscale
    install_sunshine
    install_apps
    start_sunshine
    echo
    c_ok "HOÀN TẤT. Sunshine sẵn sàng qua Tailscale."
    echo "   Tailscale IP : $(tailscale ip -4)"
    echo "   Hostname     : $TS_HOSTNAME"
    echo "   Sunshine API : $SUN_API  (user: $SUN_USER / pass: $SUN_PASS)"
    echo "   Encoder      : $(grep '^encoder' "$SUN_CONF" | awk '{print $3}')"
    echo "   Input        : XTest (không cần /dev/uinput)"
    pin_prompt_loop
    show_status
    if [ "${KEEP_ALIVE:-1}" != "0" ]; then keep_alive; fi
    ;;
esac
