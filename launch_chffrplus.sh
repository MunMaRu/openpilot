#!/usr/bin/bash

if [ -z "$BASEDIR" ]; then
  BASEDIR="/data/openpilot"
fi

source "$BASEDIR/launch_env.sh"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

function two_init {
  # convert to no ir ctrl param
  if [ -f /data/media/0/no_ir_ctrl ]; then
    echo -n 1 > /data/params/d/dp_device_no_ir_ctrl
  fi

  mount -o remount,rw /system
  # font installer
  if [ -f /EON ]; then
    if [ ! -f /system/fonts/NotoSansCJKtc-Regular.otf ]; then
      rm -fr /system/fonts/NotoSansTC*.otf
      rm -fr /system/fonts/NotoSansSC*.otf
      rm -fr /system/fonts/NotoSansKR*.otf
      rm -fr /system/fonts/NotoSansJP*.otf
      cp -rf /data/openpilot/selfdrive/assets/fonts/NotoSansCJKtc-* /system/fonts/
      cp -rf /data/openpilot/selfdrive/assets/fonts/fonts.xml /system/etc/fonts.xml
      chmod 644 /system/etc/fonts.xml
      chmod 644 /system/fonts/NotoSansCJKtc-*
    fi
  fi

  # openpilot ssh key installer
  if [ ! -f /data/params/d/GithubSshKeys ]; then
    echo -n openpilot > /data/params/d/GithubUsername
    cat /system/comma/home/setup_keys > /data/params/d/GithubSshKeys
    echo -n 1 > /data/params/d/SshEnabled
    setprop persist.neos.ssh 1
  fi
  if [ ! -f /ONEPLUS ] && ! $(grep -q "letv" /proc/cmdline); then
    sed -i -e 's#/dev/input/event1#/dev/input/event2#g' ~/.bash_profile
    touch /ONEPLUS
  else
    if [ ! -f /LEECO ]; then
      touch /LEECO
    fi
  fi
  mount -o remount,r /system

  # always update to the latest update.zip
  if [ -f /ONEPLUS ]; then
    cp -f "$BASEDIR/system/hardware/eon/update.zip" "/data/media/0/update.zip"
  fi

  # set IO scheduler
  setprop sys.io.scheduler noop
  for f in /sys/block/*/queue/scheduler; do
    echo noop > $f
  done

  # *** shield cores 2-3 ***

  # TODO: should we enable this?
  # offline cores 2-3 to force recurring timers onto the other cores
  #echo 0 > /sys/devices/system/cpu/cpu2/online
  #echo 0 > /sys/devices/system/cpu/cpu3/online
  #echo 1 > /sys/devices/system/cpu/cpu2/online
  #echo 1 > /sys/devices/system/cpu/cpu3/online

  # android gets two cores
  echo 0-1 > /dev/cpuset/background/cpus
  echo 0-1 > /dev/cpuset/system-background/cpus
  echo 0-1 > /dev/cpuset/foreground/cpus
  echo 0-1 > /dev/cpuset/foreground/boost/cpus
  echo 0-1 > /dev/cpuset/android/cpus

  # openpilot gets all the cores
  echo 0-3 > /dev/cpuset/app/cpus

  # mask off 2-3 from RPS and XPS - Receive/Transmit Packet Steering
  echo 3 | tee  /sys/class/net/*/queues/*/rps_cpus
  echo 3 | tee  /sys/class/net/*/queues/*/xps_cpus

  # *** set up governors ***

  # +50mW offroad, +500mW onroad for 30% more RAM bandwidth
  echo "performance" > /sys/class/devfreq/soc:qcom,cpubw/governor
  # available freq:
  # 192000000 307200000 384000000 441600000 537600000 614400000 691200000
  # 768000000 844800000 902400000 979200000 "1056000000" 1132800000
  # 1190400000 1286400000 1363200000 1440000000 1516800000 1593600000
  if [ -f /ONEPLUS ]; then
    echo 1363200 > /sys/class/devfreq/soc:qcom,m4m/max_freq
  else
    echo 1056000 > /sys/class/devfreq/soc:qcom,m4m/max_freq
  fi
  echo "performance" > /sys/class/devfreq/soc:qcom,m4m/governor

  # unclear if these help, but they don't seem to hurt
  echo "performance" > /sys/class/devfreq/soc:qcom,memlat-cpu0/governor
  echo "performance" > /sys/class/devfreq/soc:qcom,memlat-cpu2/governor

  # GPU
  echo "performance" > /sys/class/devfreq/b00000.qcom,kgsl-3d0/governor

  # /sys/class/devfreq/soc:qcom,mincpubw is the only one left at "powersave"
  # it seems to gain nothing but a wasted 500mW

  # *** set up IRQ affinities ***

  # Collect RIL and other possibly long-running I/O interrupts onto CPU 1
  echo 1 > /proc/irq/78/smp_affinity_list # qcom,smd-modem (LTE radio)
  echo 1 > /proc/irq/33/smp_affinity_list # ufshcd (flash storage)
  echo 1 > /proc/irq/35/smp_affinity_list # wifi (wlan_pci)
  echo 1 > /proc/irq/6/smp_affinity_list  # MDSS

  # USB traffic needs realtime handling on cpu 3
  [ -d "/proc/irq/733" ] && echo 3 > /proc/irq/733/smp_affinity_list
  if [ -f /ONEPLUS ]; then
    [ -d "/proc/irq/736" ] && echo 3 > /proc/irq/736/smp_affinity_list # USB for OP3T
  fi

  # GPU and camera get cpu 2
  CAM_IRQS="177 178 179 180 181 182 183 184 185 186 192"
  for irq in $CAM_IRQS; do
    echo 2 > /proc/irq/$irq/smp_affinity_list
  done
  echo 2 > /proc/irq/193/smp_affinity_list # GPU

  # give GPU threads RT priority
  for pid in $(pgrep "kgsl"); do
    chrt -f -p 52 $pid
  done

  # the flippening!
  LD_LIBRARY_PATH="" content insert --uri content://settings/system --bind name:s:user_rotation --bind value:i:1

  # disable bluetooth
  service call bluetooth_manager 8

  # wifi scan
  wpa_cli IFNAME=wlan0 SCAN

  # install missing libs
  LIB_PATH="/data/openpilot/system/hardware/eon/libs"
  PY_LIB_DEST="/system/comma/usr/lib/python3.8/site-packages"
  mount -o remount,rw /system
  # libgfortran
  if [ ! -f "/system/comma/usr/lib/libgfortran.so.5.0.0" ]; then
    echo "Installing libgfortran..."
    tar -zxvf "$LIB_PATH/libgfortran.tar.gz" -C /system/comma/usr/lib/
  fi
  # mapd
  MODULE="opspline"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  MODULE="overpy"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  # laika
  MODULE="hatanaka"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  if [ ! -f "$PY_LIB_DEST/ncompress.cpython-38.so" ]; then
    echo "Installing ncompress.cpython-38.so..."
    cp -f "$LIB_PATH/ncompress.cpython-38.so" "$PY_LIB_DEST/"
  fi
  MODULE="importlib_resources"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  if [ ! -f "$PY_LIB_DEST/zipp.py" ]; then
    echo "Installing zipp.py..."
    cp -f "$LIB_PATH/zipp.py" "$PY_LIB_DEST/"
  fi
  # updated
  MODULE="markdown_it"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  MODULE="mdurl"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  # panda
  if [ ! -f "$PY_LIB_DEST/spidev.cpython-38.so" ]; then
    echo "Installing spidev.cpython-38.so..."
    cp -f "$LIB_PATH/spidev.cpython-38.so" "$PY_LIB_DEST/"
  fi
  # StrEnum in values.py
  MODULE="strenum"
  if [ ! -d "$PY_LIB_DEST/$MODULE" ]; then
    echo "Installing $MODULE..."
    tar -zxvf "$LIB_PATH/$MODULE.tar.gz" -C "$PY_LIB_DEST/"
  fi
  mount -o remount,r /system

  # osm server
  if [ -f /data/params/d/dp_mapd ]; then
    dp_mapd=`cat /data/params/d/dp_mapd`
    if [ $dp_mapd == "1" ]; then
      MODULE="osm-3s_v0.7.56"
      if [ ! -d /data/media/0/osm/ ]; then
        tar -vxf "/data/openpilot/system/hardware/eon/libs/$MODULE.tar.xz" -C /data/media/0/
        mv "/data/media/0/$MODULE" /data/media/0/osm
      fi
    fi
  fi

  # Check for NEOS update
  if [ -f /LEECO ] && [ $(< /VERSION) != "$REQUIRED_NEOS_VERSION" ]; then
    echo "Installing NEOS update"
    NEOS_PY="$DIR/system/hardware/eon/neos.py"
    MANIFEST="$DIR/system/hardware/eon/neos.json"
    $NEOS_PY --swap-if-ready $MANIFEST
    $DIR/system/hardware/eon/updater $NEOS_PY $MANIFEST
  fi

  # One-time fix for a subset of OP3T with gyro orientation offsets.
  # Remove and regenerate qcom sensor registry. Only done on OP3T mainboards.
  # Performed exactly once. The old registry is preserved just-in-case, and
  # doubles as a flag denoting we've already done the reset.
  if [ -f /ONEPLUS ] && [ ! -f "/persist/comma/op3t-sns-reg-backup" ]; then
    echo "Performing OP3T sensor registry reset"
    mv /persist/sensors/sns.reg /persist/comma/op3t-sns-reg-backup &&
      rm -f /persist/sensors/sensors_settings /persist/sensors/error_log /persist/sensors/gyro_sensitity_cal &&
      echo "restart" > /sys/kernel/debug/msm_subsys/slpi &&
      sleep 5  # Give Android sensor subsystem a moment to recover
  fi

  # make sure we have the latest os version number.
  mount -o remount,rw /system
  echo -n "$REQUIRED_NEOS_VERSION" > /VERSION
  mount -o remount,r /system
}

function agnos_init {
  # wait longer for weston to come up
  if [ -f "$BASEDIR/prebuilt" ]; then
    sleep 3
  fi

  # TODO: move this to agnos
  sudo rm -f /data/etc/NetworkManager/system-connections/*.nmmeta

  # set success flag for current boot slot
  sudo abctl --set_success

  # Check if AGNOS update is required
  if [ $(< /VERSION) != "$AGNOS_VERSION" ]; then
    AGNOS_PY="$DIR/system/hardware/tici/agnos.py"
    MANIFEST="$DIR/system/hardware/tici/agnos.json"
    if $AGNOS_PY --verify $MANIFEST; then
      sudo reboot
    fi
    $DIR/system/hardware/tici/updater $AGNOS_PY $MANIFEST
  fi
}

function launch {
  # Remove orphaned git lock if it exists on boot
  [ -f "$DIR/.git/index.lock" ] && rm -f $DIR/.git/index.lock

  # Pull time from panda
  $DIR/selfdrive/boardd/set_time.py

  # Check to see if there's a valid overlay-based update available. Conditions
  # are as follows:
  #
  # 1. The BASEDIR init file has to exist, with a newer modtime than anything in
  #    the BASEDIR Git repo. This checks for local development work or the user
  #    switching branches/forks, which should not be overwritten.
  # 2. The FINALIZED consistent file has to exist, indicating there's an update
  #    that completed successfully and synced to disk.

  if [ -f "${BASEDIR}/.overlay_init" ]; then
    find ${BASEDIR}/.git -newer ${BASEDIR}/.overlay_init | grep -q '.' 2> /dev/null
    if [ $? -eq 0 ]; then
      echo "${BASEDIR} has been modified, skipping overlay update installation"
    else
      if [ -f "${STAGING_ROOT}/finalized/.overlay_consistent" ]; then
        if [ ! -d /data/safe_staging/old_openpilot ]; then
          echo "Valid overlay update found, installing"
          LAUNCHER_LOCATION="${BASH_SOURCE[0]}"

          mv $BASEDIR /data/safe_staging/old_openpilot
          mv "${STAGING_ROOT}/finalized" $BASEDIR
          cd $BASEDIR

          echo "Restarting launch script ${LAUNCHER_LOCATION}"
          unset REQUIRED_NEOS_VERSION
          unset AGNOS_VERSION
          exec "${LAUNCHER_LOCATION}"
        else
          echo "openpilot backup found, not updating"
          # TODO: restore backup? This means the updater didn't start after swapping
        fi
      fi
    fi
  fi

  # handle pythonpath
  ln -sfn $(pwd) /data/pythonpath
  export PYTHONPATH="$PWD"

  # hardware specific init
  if [ -f /EON ]; then
    two_init
  elif [ -f /TICI ]; then
    tici_init
  fi

  # write tmux scrollback to a file
  tmux capture-pane -pq -S-1000 > /tmp/launch_log

  # start manager
  cd selfdrive/manager
  ./build.py && ./manager.py

  # if broken, keep on screen error
  while true; do sleep 1; done
}

launch
