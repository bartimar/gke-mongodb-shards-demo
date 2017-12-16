#!/bin/bash
##
# Script to deploy a Kubernetes project with a StatefulSet running a MongoDB Sharded Cluster, to GKE.
##

source cluster.conf

NEW_NUM_SHARDS=4
#NUM_SHARD=$( gcloud compute instance-groups list --filter maindb --format=json --limit=1 | jq -r '.[].size' )

NEW_MAINDB_POOL_SIZE=$(( NEW_NUM_SHARDS * 2 ))
echo Y | gcloud container clusters resize --node-pool "$MAINDB_NODEPOOL_NAME" --size="$NEW_MAINDB_POOL_SIZE" "$CLUSTER_NAME"


for i in 7 8
do
  gcloud compute disks create --size "$MAINDB_DISK_SIZE"GB --type pd-ssd mongo-pd-ssd-disk-"$MAINDB_DISK_SIZE"g-$i
  sed -e "s/INST/${i}/g; s/SIZE/$MAINDB_DISK_SIZE/g" ../resources/xfs-gce-ssd-persistentvolume.yaml > /tmp/xfs-gce-ssd-persistentvolume.yaml
  kubectl apply -f /tmp/xfs-gce-ssd-persistentvolume.yaml
done

rm /tmp/xfs-gce-ssd-persistentvolume.yaml
sleep 3


# Deploy each MongoDB Shard Service using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for each MongoDB Shard Replica Set"
for i in 4
do
  sed -e "s/shardX/shard$i/g; s/ShardX/Shard$i/g; s/MAINDB_CPU/$MAINDB_CPU/g; s/MAINDB_RAM/$MAINDB_RAM/g; s/MAINDB_LIM_CPU/$MAINDB_LIM_CPU/; s/MAINDB_LIM_RAM/$MAINDB_LIM_RAM/"  ../resources/mongodb-maindb-service.yaml > /tmp/mongodb-maindb-service.yaml
  sed -e "s/shardX/shard$i/g; s/ShardX/Shard$i/g; s/ARBITER_CPU/$ARBITER_CPU/g; s/ARBITER_RAM/$ARBITER_RAM/g; s/ARBITER_LIM_CPU/$ARBITER_LIM_CPU/; s/ARBITER_LIM_RAM/$ARBITER_LIM_RAM/"  ../resources/mongodb-arbiter-service.yaml > /tmp/mongodb-arbiter-service.yaml
  kubectl apply -f /tmp/mongodb-maindb-service.yaml
  kubectl apply -f /tmp/mongodb-arbiter-service.yaml
done
rm /tmp/mongodb-*-service.yaml


# Wait until the final mongod of each Shard + the ConfigDB has started properly
echo
echo "Waiting for all the shards and configdb containers to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
sleep 30
echo -n "  "

#wait for shards
for i in 0 1
do
  for s in $(seq 1 $NEW_NUM_SHARDS)
  do
    until kubectl --v=0 exec mongod-shard$s-$i -c mongod-shard$s-container -- mongo --quiet --eval 'db.getMongo()'; do
      sleep 5
      echo -n "  "
    done
  done
done

#wait for arbiters
for i in $(seq 1 $NEW_NUM_SHARDS)
do
  until kubectl --v=0 exec mongod-shard$i-arbiter-0 -c mongod-arbiter-container -- mongo --quiet --eval 'db.getMongo()'; do
     sleep 5
    echo -n "  "
  done
done

echo "...shards & configdb containers are now running (`date`)"
echo


# Initialise the Config Server Replica Set and each Shard Replica Set
echo "Configuring each Shard Replica Set"
kubectl exec mongod-shard4-0 -c mongod-shard4-container -- mongo --eval 'rs.initiate({_id: "Shard4RepSet", version: 1, members: [ {_id: 0, host: "mongod-shard4-0.mongodb-shard4-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-shard4-1.mongodb-shard4-service.default.svc.cluster.local:27017"}, {_id: 2, host: "mongod-shard4-arbiter-0.mongodb-shard4-service.default.svc.cluster.local:27017", arbiterOnly: true} ]});'
echo


# Wait for each MongoDB Shard's Replica Set + the ConfigDB Replica Set to each have a primary ready
echo "Waiting for all the MongoDB ConfigDB & Shards' Replica Sets to initialise..."
kubectl exec mongod-shard4-0 -c mongod-shard4-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
sleep 2 # Just a little more sleep to ensure everything is ready!
echo "...initialisation of the MongoDB Replica Sets completed"
echo


# Add Shards to the Configdb
echo "Configuring ConfigDB to be aware of the 3 Shards"
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo -u "$MONGO_USER" -p"$MONGO_PASSWORD" --authenticationDatabase admin --eval 'sh.addShard("Shard4RepSet/mongod-shard4-0.mongodb-shard4-service.default.svc.cluster.local:27017");'
sleep 2

# Print Summary State
kubectl get persistentvolumes
echo
kubectl get all
echo
