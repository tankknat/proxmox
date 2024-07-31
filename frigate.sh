#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Authors: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

# Variables
LXC_NAME="frigate-nvr"
LXC_ID=105
LXC_TEMPLATE="/var/lib/vz/template/cache/debian-11-standard_11.0-1_amd64.tar.gz"
LXC_CONFIG="/etc/pve/lxc/${LXC_ID}.conf"

# Functions
function color {
  # Define your color functions here
  # Example:
  # GREEN='\033[0;32m'
  # NC='\033[0m' # No Color
}

function msg_info {
  echo -e "[INFO] $1"
}

function msg_ok {
  echo -e "[OK] $1"
}

function catch_errors {
  trap 'echo "Error on line $LINENO"; exit 1;' ERR
}

function update_os {
  msg_info "Updating OS"
  apt-get update && apt-get upgrade -y
  msg_ok "OS Updated"
}

function install_dependencies {
  msg_info "Installing Dependencies (Patience)"
  apt-get install -y curl sudo mc git gpg automake build-essential xz-utils libtool ccache pkg-config \
    libgtk-3-dev libavcodec-dev libavformat-dev libswscale-dev libv4l-dev libxvidcore-dev libx264-dev \
    libjpeg-dev libpng-dev libtiff-dev gfortran openexr libatlas-base-dev libssl-dev libtbb2 libtbb-dev \
    libdc1394-22-dev libopenexr-dev libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev gcc gfortran \
    libopenblas-dev liblapack-dev libusb-1.0-0-dev jq
  msg_ok "Installed Dependencies"
}

function install_python3_dependencies {
  msg_info "Installing Python3 Dependencies"
  apt-get install -y python3 python3-dev python3-setuptools python3-distutils python3-pip
  msg_ok "Installed Python3 Dependencies"
}

function install_nodejs {
  msg_info "Installing Node.js"
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
  msg_ok "Installed Node.js"
}

function install_go2rtc {
  msg_info "Installing go2rtc"
  mkdir -p /usr/local/go2rtc/bin
  cd /usr/local/go2rtc/bin
  wget -qO go2rtc "https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_amd64"
  chmod +x go2rtc
  ln -svf /usr/local/go2rtc/bin/go2rtc /usr/local/bin/go2rtc
  msg_ok "Installed go2rtc"
}

function setup_hardware_acceleration {
  msg_info "Setting Up Hardware Acceleration"
  apt-get -y install va-driver-all ocl-icd-libopencl1 intel-opencl-icd vainfo intel-gpu-tools
  if [[ "$CTTYPE" == "0" ]]; then
    chgrp video /dev/dri
    chmod 755 /dev/dri
    chmod 660 /dev/dri/*
  fi
  msg_ok "Set Up Hardware Acceleration"
}

function install_frigate {
  RELEASE=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases/latest | jq -r '.tag_name')
  msg_info "Installing Frigate $RELEASE (Perseverance)"
  cd ~
  mkdir -p /opt/frigate/models
  wget -q https://github.com/blakeblackshear/frigate/archive/refs/tags/${RELEASE}.tar.gz -O frigate.tar.gz
  tar -xzf frigate.tar.gz -C /opt/frigate --strip-components 1
  rm -rf frigate.tar.gz
  cd /opt/frigate
  pip3 wheel --wheel-dir=/wheels -r /opt/frigate/docker/main/requirements-wheels.txt
  cp -a /opt/frigate/docker/main/rootfs/. /
  export TARGETARCH="amd64"
  echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
  wget -q -O /opt/frigate/docker/main/install_deps.sh https://raw.githubusercontent.com/blakeblackshear/frigate/dev/docker/main/install_deps.sh
  /opt/frigate/docker/main/install_deps.sh
  ln -svf /usr/lib/btbn-ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg
  ln -svf /usr/lib/btbn-ffmpeg/bin/ffprobe /usr/local/bin/ffprobe
  pip3 install -U /wheels/*.whl
  ldconfig
  pip3 install -r /opt/frigate/docker/main/requirements-dev.txt
  /opt/frigate/.devcontainer/initialize.sh
  make version
  cd /opt/frigate/web
  npm install
  npm run build
  cp -r /opt/frigate/web/dist/* /opt/frigate/web/
  cp -r /opt/frigate/config/. /config
  sed -i '/^s6-svc -O \.$/s/^/#/' /opt/frigate/docker/main/rootfs/etc/s6-overlay/s6-rc.d/frigate/run
  cat <<EOF >/config/config.yml
mqtt:
  enabled: false
cameras:
  test:
    ffmpeg:
      #hwaccel_args: preset-vaapi
      inputs:
        - path: /media/frigate/person-bicycle-car-detection.mp4
          input_args: -re -stream_loop -1 -fflags +genpts
          roles:
            - detect
            - rtmp
    detect:
      height: 1080
      width: 1920
      fps: 5
EOF
  ln -sf /config/config.yml /opt/frigate/config/config.yml
  if [[ "$CTTYPE" == "0" ]]; then
    sed -i -e 's/^kvm:x:104:$/render:x:104:root,frigate/' -e 's/^render:x:105:root$/kvm:x:105:/' /etc/group
  else
    sed -i -e 's/^kvm:x:104:$/render:x:104:frigate/' -e 's/^render:x:105:$/kvm:x:105:/' /etc/group
  fi
  echo "tmpfs   /tmp/cache      tmpfs   defaults        0       0" >> /etc/fstab
  msg_ok "Installed Frigate $RELEASE"
}

function install_openvino_model {
  if grep -q -o -m1 'avx[^ ]*' /proc/cpuinfo; then
    msg_info "Installing Openvino Object Detection Model (Resilience)"
    pip install -r /opt/frigate/docker/main/requirements-ov.txt
    cd /opt/frigate/models
    export ENABLE_ANALYTICS=NO
    /usr/local/bin/omz_downloader --name ssdlite_mobilenet_v2 --num_attempts 2
    /usr/local/bin/omz_converter --name ssdlite_mobilenet_v2 --precision FP16 --mo /usr/local/bin/mo
    cd /
    cp -r /opt/frigate/models/public/ssdlite_mobilenet_v2 openvino-model
    wget -q https://github.com/openvinotoolkit/open_model_zoo/raw/master/data/dataset_classes/coco_91cl_bkgr.txt -O openvino-model/coco_91cl_bkgr.txt
    sed -i 's/truck/car/g' openvino-model/coco_91cl_bkgr.txt
    cat <<EOF >>/config/config.yml
detectors:
  ov:
    type: openvino
    device: AUTO
    model:
      path: /openvino-model/FP16/ssdlite_mobilenet_v2.xml
model:
  width: 300
  height: 300
  input_tensor: nhwc
  input_pixel_format: bgr
  labelmap_path: /openvino-model/coco_91cl_bkgr.txt
EOF
    msg_ok "Installed Openvino Object Detection Model"
  else
    cat <<EOF >>/config/config.yml
model:
  path: /cpu_model.tflite
EOF
  fi
}

function install_coral_model {
  msg_info "Installing Coral Object Detection Model (Patience)"
  cd /opt/frigate
  export CCACHE_DIR=/root/.ccache
  export CCACHE_MAXSIZE=2G
  wget -q https://github.com/libusb/libusb/archive/v1.0.26.zip
  unzip -q v1.0.26.zip
  rm v1.0.26.zip
  cd libusb-1.0.26
  ./autogen.sh
  ./configure
  make -j"$(nproc)"
  make install
  cd ..
  wget -q https://github.com/Coral/edgetpu/archive/refs/tags/v2.14.0.zip
  unzip -q v2.14.0.zip
  cd edgetpu-2.14.0
  python3 setup.py install
  msg_ok "Installed Coral Object Detection Model"
}

# Script Execution
catch_errors
update_os
install_dependencies
install_python3_dependencies
install_nodejs
install_go2rtc
setup_hardware_acceleration
install_frigate
install_openvino_model
install_coral_model

msg_ok "Frigate Installation and Setup Complete"
