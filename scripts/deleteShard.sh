#!/bin/bash
##
# Script to remove/undepoy all project resources from GKE & GCE.
##

# load global config
source cluster.conf

#remove shard from cluster
echo "Removing shard from cluster"
until [[ $(kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --quiet --eval "db.getSiblingDB(\"admin\").auth(\"$MONGO_USER\", \"$MONGO_PASSWORD\"); db.adminCommand({ removeShard: \"Shard${NUM_SHARDS}RepSet\"})" | jq -r '.state') == "completed" ]]; do
    sleep 1
    echo -n "."
done
echo

NEW_SHARD_1_IDX=$(( NUM_SHARDS * 2 - 1 ))
NEW_SHARD_2_IDX=$(( NUM_SHARDS * 2 ))

# Delete persistent volumes
for i in $NEW_SHARD_1_IDX $NEW_SHARD_2_IDX
do
    kubectl delete persistentvolumes mongo-data-volume-${MAINDB_DISK_SIZE}g-$i
done
sleep 20

# Delete GCE disks
for i in $NEW_SHARD_1_IDX $NEW_SHARD_2_IDX
do
    gcloud -q compute disks delete mongo-pd-ssd-disk-${MAINDB_DISK_SIZE}g-$i
done

# Delete mongos deployment + mongod stateful set + mongodb service + secrets + host vm configurer daemonset
kubectl delete statefulsets mongod-shard$NUM_SHARDS mongod-shard$NUM_SHARDS-arbiter
kubectl delete services mongodb-shard$NUM_SHARDS-service

NEW_NUM_SHARDS=$(( NUM_SHARDS - 1 ))
sed -i "s/NUM_SHARDS=.*/NUM_SHARDS=$NEW_NUM_SHARDS/" cluster.conf

sleep 3
