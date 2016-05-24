#/bin/sh

set -e

VOLUMN_ID=$1
DEVICE_FLAG=$2

if [ -z "$DEVICE_FLAG" ]; then
DEVICE_FLAG="f"
fi

aws ec2 attach-volume --instance-id i-cbd75854 --volume-id "$VOLUMN_ID" --device "/dev/sd${DEVICE_FLAG}"

echo "Waiting for attaching ..."
until sleep 1 && lsblk | grep "xvd${DEVICE_FLAG}"; do
printf .
done

MOUNT_PATH=/mnt/source
if [ ! -d "$MOUNT_PATH" ]; then
  mkdir -p "$MOUNT_PATH"
fi

echo "Mount '/dev/xvd${DEVICE_FLAG}2' to '$MOUNT_PATH'"
mount "/dev/xvd${DEVICE_FLAG}2" "$MOUNT_PATH"

mkdir "$VOLUMN_ID"

echo "Mount all files in '$MOUNT_PATH' to under '$VOLUMN_ID'"
mv $MOUNT_PATH/* "$VOLUMN_ID/"

echo "Unmount '$MOUNT_PATH'"
umount "$MOUNT_PATH"

echo "Detach volume $VOLUMN_ID"
aws ec2 detach-volume --volume-id "$VOLUMN_ID"

echo "Waiting for detaching ..."
while sleep 1 && lsblk | grep "xvd${DEVICE_FLAG}"; do
printf .
done
