#!/bin/bash

source cluster.conf

echo "Testing sharding"

read -r -d '' CMD << END
db.getSiblingDB('admin').auth("$MONGO_USER", "$MONGO_PASSWORD");
sh.enableSharding("test");
sh.shardCollection("test.testcoll", {"myfield": 1});
use test;
db.testcoll.insert({"myfield": "a", "otherfield": "b"});
db.testcoll.find();
sh.status();
use config
db.settings.update({ _id : "balancer" }, { $unset : { activeWindow : true } })

END
echo "Executing:"
echo "$CMD"

kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --authenticationDatabase admin  --username "$MONGO_USER" --password "$MONGO_PASSWORD" --eval "$CMD"

echo "Testing replicaSets"
for i in $NUM_SHARDS
do
  kubectl exec -it mongod-shard$i-0 -- mongo --authenticationDatabase admin  --username "$MONGO_USER" --password "$MONGO_PASSWORD" --eval "rs.status()"
done

echo "Importing data"
kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- sh -c 'apt-get update && apt-get install -y wget ; wget https://raw.githubusercontent.com/mongodb/docs-assets/primer-dataset/primer-dataset.json ; mongoimport --db test --authenticationDatabase admin  --username '"$MONGO_USER"' --password '"$MONGO_PASSWORD"' --collection restaurants --drop --file primer-dataset.json '

echo "Check affinity"
for i in $(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.kubernetes\.io/hostname}'); do echo "Node: $i"; kubectl get pods -o wide | grep "$i"; echo "-----------------"; done  |grep -v 'hostvm' | grep -v 'configdb' | grep -v 'default-pool' |  egrep --color 'mongod-shard|^'
