#!/bin/bash
set -e

source /opt/ros/humble/setup.bash
source /opt/ros-humble-ros1-bridge/local_setup.bash

# Force UDP transport instead of Fast-DDS shared memory: SHM segments
# don't reliably match up between this container and a native host ros2
# process even with --ipc=host, which silently breaks message delivery
# while discovery still appears to work. Override if you know your setup
# handles SHM correctly.
export FASTDDS_BUILTIN_TRANSPORTS="${FASTDDS_BUILTIN_TRANSPORTS:-UDPv4}"

if [[ -z "${ROS_MASTER_URI}" ]]; then
  echo "WARNING: ROS_MASTER_URI is not set. The bridge needs to reach the" >&2
  echo "ROS1 master that your OptiTrack driver / roscore is running on," >&2
  echo "e.g. -e ROS_MASTER_URI=http://192.168.1.50:11311" >&2
fi

echo "Starting: ros2 run ros1_bridge $*"
exec ros2 run ros1_bridge "$@"
