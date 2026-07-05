# =========================================================================
# ros1_bridge (Noetic <-> Humble) — build + runtime image
#
# Stage 1 "builder": compiles ros1_bridge on top of ros:humble-ros-base by
#   temporarily force-installing ROS1 Noetic dev headers/libs on Jammy.
#   This is slow (20-40 min) and needs a few GB of RAM.
# Stage 2 "runtime": a lean ros-humble-ros-base image containing only the
#   compiled bridge + the handful of .so files it needs from ROS1.
#
# Build:
#   docker build -t ros1_bridge:humble-noetic .
#
# Run (host networking is required — ROS1 uses dynamically negotiated
# TCPROS ports that don't survive normal Docker port mapping):
#   docker run --rm -it --net=host \
#     -e ROS_MASTER_URI=http://<optitrack-ros1-host>:11311 \
#     -e ROS_IP=<this-machine-ip> \
#     ros1_bridge:humble-noetic
# =========================================================================

# ---------------------------------------------------------------------
# Stage 1: builder
# ---------------------------------------------------------------------
FROM ros:humble-ros-base-jammy AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-c"]

# 1) Bring the Humble base up to date
RUN apt-get -y update && apt-get -y upgrade

# 2) Temporarily disable the ROS2 apt repo so we can pull ROS1 packages
RUN mv /etc/apt/sources.list.d/ros2.sources /root/ \
    && apt-get update

# 3) Work around the catkin/ament package conflict
RUN sed -i -e 's|^Conflicts: catkin|#Conflicts: catkin|' /var/lib/dpkg/status \
    && apt-get install -f -y

# 4) Force-install ROS1's python tooling (built for focal, but works fine here)
RUN apt-get download python3-catkin-pkg python3-rospkg python3-rosdistro \
    && dpkg --force-overwrite -i python3-catkin-pkg*.deb \
    && dpkg --force-overwrite -i python3-rospkg*.deb \
    && dpkg --force-overwrite -i python3-rosdistro*.deb \
    && apt-get install -f -y

# 5) Install ROS1 desktop *dev* headers/libs (this is what lets ros1_bridge
#    compile against ROS1 message/service types)
RUN apt-get -y install ros-desktop-dev

# 5b) rviz (pulled in via ros-desktop-dev) needs OpenGL dev libs for its
#     pkg-config check, or the ros1_bridge cmake configure step fails with
#     "pkg-config module 'rviz' failed to find library 'OpenGL'"
RUN apt-get -y install libgl1-mesa-dev libglu1-mesa-dev freeglut3-dev

# ARM64 pkgconfig path fix (harmless on amd64)
RUN if [[ "$(uname -m)" = "arm64" || "$(uname -m)" = "aarch64" ]]; then \
        cp /usr/lib/x86_64-linux-gnu/pkgconfig/* /usr/lib/aarch64-linux-gnu/pkgconfig/; \
    fi

# 6) Restore the ROS2 apt repo
RUN mv /root/ros2.sources /etc/apt/sources.list.d/ \
    && apt-get -y update

# Build args: set to 1 to also bridge ros_tutorials example types (handy
# for smoke-testing with `rostopic pub /chatter ...`). Leave others at 0
# unless you specifically need grid_map / octomap / custom action bridging.
ARG ADD_ros_tutorials=1
ARG ADD_custom_action_mapping=0

RUN if [[ "$ADD_ros_tutorials" = "1" ]]; then \
        git clone -b noetic-devel --depth=1 https://github.com/ros/ros_tutorials.git; \
        cd ros_tutorials; unset ROS_DISTRO; \
        colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release; \
        cd ..; source ros_tutorials/install/setup.bash; \
        git clone -b fuerte-devel --depth=1 https://github.com/ros/common_tutorials.git; \
        cd common_tutorials; unset ROS_DISTRO; \
        colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release; \
    fi

RUN if [[ "$ADD_custom_action_mapping" = "1" ]]; then \
        cd /; \
        git clone --depth=1 -b kinetic-devel https://github.com/ros-controls/control_msgs.git control_msgs_ros1; \
        cd /control_msgs_ros1; unset ROS_DISTRO; \
        colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release; \
        cd /; \
        git clone --depth=1 -b humble https://github.com/ros-controls/control_msgs.git control_msgs_ros2; \
        cd /control_msgs_ros2; unset ROS_DISTRO; source /opt/ros/humble/setup.bash; \
        colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release; \
    fi

# 7) Compile ros1_bridge itself, overlaying whatever extras were enabled above
RUN source /opt/ros/humble/setup.bash; \
    if [[ "$ADD_ros_tutorials" = "1" ]]; then \
        source ros_tutorials/install/setup.bash; \
        source common_tutorials/install/setup.bash; \
        apt-get -y install ros-humble-example-interfaces; \
        source /opt/ros/humble/setup.bash; \
    fi; \
    if [[ "$ADD_custom_action_mapping" = "1" ]]; then \
        source /control_msgs_ros1/install/setup.bash; \
        source /control_msgs_ros2/install/setup.bash; \
    fi; \
    mkdir -p /ros-humble-ros1-bridge/src; \
    cd /ros-humble-ros1-bridge/src; \
    git clone -b master --depth=1 https://github.com/ros2/ros1_bridge.git; \
    cd ../..; \
    MEMG=$(printf "%.0f" $(free -g | awk '/^Mem:/{print $2}')); \
    NPROC=$(nproc); MIN=$((MEMG<NPROC ? MEMG : NPROC)); MIN=$((MIN<1 ? 1 : MIN)); \
    cd /ros-humble-ros1-bridge; \
    MAKEFLAGS="-j $MIN" colcon build --event-handlers console_direct+ \
        --cmake-args -DCMAKE_BUILD_TYPE=Release

# 8) Pull the handful of ROS1 shared libs the bridge binary needs at runtime,
#    since the final image won't have ros-desktop-dev installed.
RUN ROS1_LIBS="libxmlrpcpp.so librostime.so libroscpp.so libroscpp_serialization.so \
        librosconsole.so librosconsole_log4cxx.so librosconsole_backend_interface.so \
        liblog4cxx.so libcpp_common.so libb64.so libaprutil-1.so libapr-1.so libactionlib.so.1d"; \
    mkdir -p /ros-humble-ros1-bridge/install/ros1_bridge/ros1_libs; \
    cd /ros-humble-ros1-bridge/install/ros1_bridge/lib; \
    for soFile in $ROS1_LIBS; do \
        soFilePath=$(ldd libros1_bridge.so | grep "$soFile" | awk '{print $3;}') || true; \
        if [[ -n "$soFilePath" ]]; then cp "$soFilePath" ./; fi; \
    done

# ---------------------------------------------------------------------
# Stage 2: runtime — small image with Humble + the compiled bridge only
# ---------------------------------------------------------------------
FROM ros:humble-ros-base-jammy AS runtime

# Anything the OptiTrack/ROS1 side needs on this machine, e.g. rostopic/rosrun
# tooling for debugging, is optional. Uncomment if you want it:
# RUN apt-get update && apt-get -y install ros-humble-example-interfaces \
#     && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get -y install \
    libboost-thread1.74.0 libboost-system1.74.0 libboost-filesystem1.74.0 \
    libboost-regex1.74.0 libboost-program-options1.74.0 libboost-chrono1.74.0 \
    libboost-date-time1.74.0 libboost-atomic1.74.0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /ros-humble-ros1-bridge/install /opt/ros-humble-ros1-bridge

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["dynamic_bridge", "--bridge-all-topics"]
