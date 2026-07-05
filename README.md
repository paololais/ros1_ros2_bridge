# ros1_bridge: Noetic ↔ Humble (OptiTrack → ROS2)

Bridges ROS1 (Noetic) topics to ROS2 (Humble).

## Quick start

```bash
git clone <this-repo-url>
cd /path/to/ros1_bridge_docker
```

Build the image (~15-25 min, one-time)
```bash
docker build -t ros1_bridge:humble-noetic --build-arg ADD_ros_tutorials=0 .
```

## Configuration

| Variable | Meaning |
|---|---|
| `ROS_MASTER_URI` | Address of the ROS1 `roscore` your OptiTrack driver publishes to |
| `ROS_IP` | IP this container advertises itself as on the ROS1 side |
| `ROS_DOMAIN_ID` | Must match whatever your ROS2 side (host, other nodes) uses |

## Running

```bash
docker run --rm -i --net=host --ipc=host \
  -e ROS_MASTER_URI=http://localhost:11311 \
  -e ROS_IP=127.0.0.1 \
  -e ROS_DOMAIN_ID=42 \
  ros1_bridge:humble-noetic \
  dynamic_bridge --bridge-all-1to2-topics 2>/dev/null
```

