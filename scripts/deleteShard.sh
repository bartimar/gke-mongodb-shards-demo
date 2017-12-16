#!/bin/bash
##
# Script to remove/undepoy all project resources from GKE & GCE.
##

# load global config
source cluster.conf

#remove shard from cluster
echo "Removing shard from cluster"
until [[ $(kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --quiet --eval 'db.getSiblingDB("admin").auth("main_admin", "abc123"); db.adminCommand({ removeShard: "Shard4RepSet"})' | jq -r '.state') == "completed" ]]; do
    sleep 1
    echo -n "."
done
echo 

# Delete persistent volumes
for i in 7 8 
do
    kubectl delete persistentvolumes marek-data-volume-${MAINDB_DISK_SIZE}g-$i
done
sleep 20

# Delete GCE disks
for i in 7 8 
do
    gcloud -q compute disks delete marek-pd-ssd-disk-${MAINDB_DISK_SIZE}g-$i
done

# Delete mongos deployment + mongod stateful set + mongodb service + secrets + host vm configurer daemonset
kubectl delete statefulsets mongod-shard4 mongod-shard4-arbiter
kubectl delete services mongodb-shard4-service

sleep 3
