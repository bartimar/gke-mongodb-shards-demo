#!/bin/bash
##
# Script to deploy a Kubernetes project with a StatefulSet running a MongoDB Sharded Cluster, to GKE.
##

source cluster.conf

# Create new GKE Kubernetes cluster (using host node VM images based on Ubuntu
# rather than default ChromiumOS & also use slightly larger VMs than default)
echo "Creating GKE Cluster"
gcloud container clusters list --filter="$CLUSTER_NAME" --format=json | grep -qv '\[\]' || gcloud container clusters create "$CLUSTER_NAME" --scopes="$SCOPES" --machine-type="$DEFAULT_POOL_MACHINE_TYPE" --image-type="$IMAGE_TYPE" --num-nodes="$DEFAULT_POOL_NUM_NODES"
gcloud container clusters get-credentials "$CLUSTER_NAME"

echo "Creating node pools"
# mongos, primary, secondary and arbiters run on "SHARD" nodes
gcloud container node-pools create "$MAINDB_NODEPOOL_NAME"    --cluster="$CLUSTER_NAME" --image-type=UBUNTU --machine-type="$MAINDB_MACHINE_TYPE"   --num-nodes="$MAINDB_NUM_NODES"   --node-labels=mongo-node="shard"
gcloud container node-pools create "$CONFIGDB_NODEPOOL_NAME"  --cluster="$CLUSTER_NAME" --image-type=UBUNTU --machine-type="$CONFIGDB_MACHINE_TYPE" --num-nodes="$CONFIGDB_NUM_NODES" --node-labels=mongo-role="$CONFIGDB_NODEPOOL_NAME"
#gcloud container node-pools create "$ARBITER_NODEPOOL_NAME"   --cluster="$CLUSTER_NAME" --image-type=UBUNTU --machine-type="$ARBITER_MACHINE_TYPE"  --num-nodes="$ARBITER_NUM_NODES"  --node-labels=mongo-role="$ARBITER_NODEPOOL_NAME"
#gcloud container node-pools create "$MONGOS_NODEPOOL_NAME"    --cluster="$CLUSTER_NAME" --image-type=UBUNTU --machine-type="$MONGOS_MACHINE_TYPE"   --num-nodes="$MONGOS_NUM_NODES"   --node-labels=mongo-role="$MONGOS_NODEPOOL_NAME"

# Configure host VM using daemonset to disable hugepages
echo "Deploying GKE Daemon Set"
kubectl apply -f ../resources/hostvm-node-configurer-daemonset.yaml

# Register GCE Fast SSD persistent disks and then create the persistent disks
echo "Creating GCE disks"
kubectl apply -f ../resources/gce-ssd-storageclass.yaml
sleep 5
for i in $(seq 1 $NUM_SHARDS)
do
    gcloud compute disks create --size "$CONFIGDB_DISK_SIZE"GB --type pd-ssd mongo-pd-ssd-disk-"$CONFIGDB_DISK_SIZE"g-$i
done
for i in $(seq 1 $MAINDB_NUM_NODES)
do
    gcloud compute disks create --size "$MAINDB_DISK_SIZE"GB --type pd-ssd mongo-pd-ssd-disk-"$MAINDB_DISK_SIZE"g-$i
done
sleep 3


# Create persistent volumes using disks created above
echo "Creating GKE Persistent Volumes"
for i in $(seq 1 $NUM_SHARDS)
do
    # Replace text stating volume number + size of disk (set to 4)
    sed -e "s/INST/${i}/g; s/SIZE/$CONFIGDB_DISK_SIZE/g" ../resources/xfs-gce-ssd-persistentvolume.yaml > /tmp/xfs-gce-ssd-persistentvolume.yaml
    kubectl apply -f /tmp/xfs-gce-ssd-persistentvolume.yaml
done
for i in $(seq 1 $MAINDB_NUM_NODES)
do
    # Replace text stating volume number + size of disk (set to 8)
    sed -e "s/INST/${i}/g; s/SIZE/$MAINDB_DISK_SIZE/g" ../resources/xfs-gce-ssd-persistentvolume.yaml > /tmp/xfs-gce-ssd-persistentvolume.yaml
    kubectl apply -f /tmp/xfs-gce-ssd-persistentvolume.yaml
done
rm /tmp/xfs-gce-ssd-persistentvolume.yaml
sleep 3


# Create keyfile for the MongoDB cluster as a Kubernetes shared secret
TMPFILE=$(mktemp)
/usr/bin/openssl rand -base64 741 > $TMPFILE
kubectl create secret generic shared-bootstrap-data --from-file=internal-auth-mongodb-keyfile=$TMPFILE
rm $TMPFILE


# Deploy a MongoDB ConfigDB Service ("Config Server Replica Set") using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for MongoDB Config Server Replica Set"
sed -e "s/CONFIGDB_CPU/$CONFIGDB_CPU/g; s/CONFIGDB_RAM/$CONFIGDB_RAM/g;  s/CONFIGDB_LIM_CPU/$CONFIGDB_LIM_CPU/g; s/CONFIGDB_LIM_RAM/$CONFIGDB_LIM_RAM/g"  ../resources/mongodb-configdb-service.yaml > /tmp/mongodb-configdb-service.yaml
kubectl apply -f /tmp/mongodb-configdb-service.yaml


# Deploy each MongoDB Shard Service using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for each MongoDB Shard Replica Set"
# Deploy some Mongos Routers using a Kubernetes Deployment
echo "Deploying GKE Deployment & Service for some Mongos Routers"
for i in $(seq 1 $NUM_SHARDS)
do
  sed -e "s/shardX/shard$i/g; s/ShardX/Shard$i/g; s/MAINDB_CPU/$MAINDB_CPU/g; s/MAINDB_RAM/$MAINDB_RAM/g; s/MAINDB_LIM_CPU/$MAINDB_LIM_CPU/; s/MAINDB_LIM_RAM/$MAINDB_LIM_RAM/"  ../resources/mongodb-maindb-service.yaml > /tmp/mongodb-maindb-service-$i.yaml
  sed -e "s/shardX/shard$i/g; s/ShardX/Shard$i/g; s/ARBITER_CPU/$ARBITER_CPU/g; s/ARBITER_RAM/$ARBITER_RAM/g; s/ARBITER_LIM_CPU/$ARBITER_LIM_CPU/; s/ARBITER_LIM_RAM/$ARBITER_LIM_RAM/"  ../resources/mongodb-arbiter-service.yaml > /tmp/mongodb-arbiter-service-$i.yaml
  sed -e "s/shardX/shard$i/g; s/ShardX/Shard$i/g; s/MONGOS_CPU/$MONGOS_CPU/g; s/MONGOS_RAM/$MONGOS_RAM/g; s/MONGOS_LIM_CPU/$MONGOS_LIM_CPU/;s/MONGOS_LIM_RAM/$MONGOS_LIM_RAM/;"  ../resources/mongodb-mongos-deployment.yaml > /tmp/mongodb-mongos-deployment-$i.yaml
done
echo "Applying yamls"
for i in $(seq 1 $NUM_SHARDS)
do
  kubectl apply -f /tmp/mongodb-maindb-service-$i.yaml
  sleep 10
done
sleep 120
for i in $(seq 1 $NUM_SHARDS)
do
  kubectl apply -f /tmp/mongodb-arbiter-service-$i.yaml
  sleep 10
done
sleep 60
for i in $(seq 1 $NUM_SHARDS)
do
  kubectl apply -f /tmp/mongodb-mongos-deployment-$i.yaml
  sleep 10
done
rm /tmp/mongodb-*.yaml

# Wait until the final mongod of each Shard + the ConfigDB has started properly
echo
echo "Waiting for all the shards and configdb containers to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
sleep 30
echo -n "  "


echo wait for configdb
for i in $(seq 0 $((NUM_SHARDS - 1)) )
do
  until kubectl --v=0 exec mongod-configdb-$i -c mongod-configdb-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 5
    echo -n "  "
  done
done

echo wait for shards
for i in 0 1
do
  for s in $(seq 1 $NUM_SHARDS)
  do
    until kubectl --v=0 exec mongod-shard$s-$i -c mongod-shard$s-container -- mongo --quiet --eval 'db.getMongo()'; do
      sleep 5
      echo -n "  "
    done
  done
done

echo wait for arbiters
for i in $(seq 1 $NUM_SHARDS)
do
  until kubectl --v=0 exec $(kubectl get pod -l "tier=arbiter" -o jsonpath='{.items[0].metadata.name}') -c mongod-arbiter-container -- mongo --quiet --eval 'db.getMongo()'; do
     sleep 5
    echo -n "  "
  done
done

echo "...shards & configdb containers are now running (`date`)"
echo


# Initialise the Config Server Replica Set and each Shard Replica Set
echo "Configuring Config Server & Shards' Replica Sets"
kubectl exec mongod-configdb-0 -c mongod-configdb-container -- mongo --eval 'rs.initiate({_id: "ConfigDBRepSet", version: 1, members: [ {_id: 0, host: "mongod-configdb-0.mongodb-configdb-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-configdb-1.mongodb-configdb-service.default.svc.cluster.local:27017"}, {_id: 2, host: "mongod-configdb-2.mongodb-configdb-service.default.svc.cluster.local:27017"} ]});'
echo "Configuring each Shard Replica Set"
kubectl exec mongod-shard1-0 -c mongod-shard1-container -- mongo --eval 'rs.initiate({_id: "Shard1RepSet", version: 1, members: [ {_id: 0, host: "mongod-shard1-0.mongodb-shard1-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-shard1-1.mongodb-shard1-service.default.svc.cluster.local:27017"}, {_id: 2, host: "mongod-shard1-arbiter-0.mongodb-shard1-service.default.svc.cluster.local:27017", arbiterOnly: true} ]});'
kubectl exec mongod-shard2-0 -c mongod-shard2-container -- mongo --eval 'rs.initiate({_id: "Shard2RepSet", version: 1, members: [ {_id: 0, host: "mongod-shard2-0.mongodb-shard2-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-shard2-1.mongodb-shard2-service.default.svc.cluster.local:27017"}, {_id: 2, host: "mongod-shard2-arbiter-0.mongodb-shard2-service.default.svc.cluster.local:27017", arbiterOnly: true} ]});'
kubectl exec mongod-shard3-0 -c mongod-shard3-container -- mongo --eval 'rs.initiate({_id: "Shard3RepSet", version: 1, members: [ {_id: 0, host: "mongod-shard3-0.mongodb-shard3-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-shard3-1.mongodb-shard3-service.default.svc.cluster.local:27017"}, {_id: 2, host: "mongod-shard3-arbiter-0.mongodb-shard3-service.default.svc.cluster.local:27017", arbiterOnly: true} ]});'
echo


# Wait for each MongoDB Shard's Replica Set + the ConfigDB Replica Set to each have a primary ready
echo "Waiting for all the MongoDB ConfigDB & Shards' Replica Sets to initialise..."
kubectl exec mongod-configdb-0 -c mongod-configdb-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
kubectl exec mongod-shard1-0 -c mongod-shard1-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
kubectl exec mongod-shard2-0 -c mongod-shard2-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
kubectl exec mongod-shard3-0 -c mongod-shard3-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
sleep 2 # Just a little more sleep to ensure everything is ready!
echo "...initialisation of the MongoDB Replica Sets completed"
echo


# Wait for the mongos to have started properly
echo "Waiting for the first mongos to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
echo -n "  "
until kubectl --v=0 exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 2
    echo -n "  "
done
echo "...first mongos is now running (`date`)"
echo


# Add Shards to the Configdb
echo "Configuring ConfigDB to be aware of the 3 Shards"
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --eval 'sh.addShard("Shard1RepSet/mongod-shard1-0.mongodb-shard1-service.default.svc.cluster.local:27017");'
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --eval 'sh.addShard("Shard2RepSet/mongod-shard2-0.mongodb-shard2-service.default.svc.cluster.local:27017");'
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --eval 'sh.addShard("Shard3RepSet/mongod-shard3-0.mongodb-shard3-service.default.svc.cluster.local:27017");'
sleep 2


# Create the Admin User (this will automatically disable the localhost exception)
echo "Creating user: '$MONGO_USER'"
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --eval 'db.getSiblingDB("admin").createUser({user:"'"${MONGO_USER}"'",pwd:"'"${MONGO_PASSWORD}"'",roles:[{role:"root",db:"admin"}]});'
echo


# Print Summary State
kubectl get persistentvolumes
echo
kubectl get all
echo
