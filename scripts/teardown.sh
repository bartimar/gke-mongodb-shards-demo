#!/bin/bash
##
# Script to remove/undepoy all project resources from GKE & GCE.
##

# load global config
source cluster.conf

# Delete mongos deployment + mongod stateful set + mongodb service + secrets + host vm configurer daemonset
kubectl delete deployments mongos
for i in $(seq 1 $NUM_SHARDS)
do
  kubectl delete statefulsets mongod-shard$i-arbiter mongod-shard$i mongos-shard$i &
  kubectl delete services mongodb-shard$i-service &
  #kubectl delete deployments mongos-shard$i  &
done
kubectl delete statefulsets mongod-configdb
kubectl delete services mongodb-configdb-service
kubectl delete secret shared-bootstrap-data
kubectl delete daemonset hostvm-configurer
sleep 3

# Delete persistent volume claims
kubectl delete persistentvolumeclaims -l tier="$MAINDB_NODEPOOL_NAME"
kubectl delete persistentvolumeclaims -l tier="$CONFIGDB_NODEPOOL_NAME"
sleep 3

# Delete persistent volumes
for i in $(seq 1 $NUM_SHARD)
do
    kubectl delete persistentvolumes mongo-data-volume-${CONFIGDB_DISK_SIZE}g-$i
done
for i in $(seq 1 $MAINDB_NUM_NODES)
do
    kubectl delete persistentvolumes mongo-data-volume-${MAINDB_DISK_SIZE}g-$i
done
sleep 20

# Delete GCE disks
for i in  $(seq 1 $NUM_SHARD)
do
    gcloud -q compute disks delete mongo-pd-ssd-disk-${CONFIGDB_DISK_SIZE}g-$i
done
for i in $(seq 1 $MAINDB_NUM_NODES)
do
    gcloud -q compute disks delete mongo-pd-ssd-disk-${MAINDB_DISK_SIZE}g-$i
done

# Delete whole Kubernetes cluster (including its VM instances)
gcloud -q container node-pools delete "$MAINDB_NODEPOOL_NAME"   --cluster="$CLUSTER_NAME"
gcloud -q container node-pools delete "$CONFIGDB_NODEPOOL_NAME" --cluster="$CLUSTER_NAME"
gcloud -q container node-pools delete "$ARBITER_NODEPOOL_NAME"  --cluster="$CLUSTER_NAME"
gcloud -q container node-pools delete "$MONGOS_NODEPOOL_NAME"   --cluster="$CLUSTER_NAME"
gcloud -q container clusters delete "$CLUSTER_NAME"
