#!/bin/bash

echo "Testing sharding"

read -r -d '' CMD << END
db.getSiblingDB('admin').auth("main_admin", "abc123");
sh.enableSharding("test");
sh.shardCollection("test.testcoll", {"myfield": 1});
use test;
db.testcoll.insert({"myfield": "a", "otherfield": "b"});
db.testcoll.find();
sh.status();
sh.enableSharding("tapito");
sh.shardCollection("tapito.articles_keywords", {"_id": 1});
sh.shardCollection("tapito.user-article-action", {"_id": 1});
sh.shardCollection("tapito.articles", {"_id": 1});
sh.status();
use config
db.settings.update({ _id : "balancer" }, { $unset : { activeWindow : true } })

END
echo "Executing:"
echo "$CMD"

kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval "$CMD"

# Add Shards to the Configdb
echo "Configuring ConfigDB to be aware of the 3 Shards"
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval 'sh.addShard("Shard1RepSet/mongod-shard1-0.mongodb-shard1-service.default.svc.cluster.local:27017");'
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval 'sh.addShard("Shard2RepSet/mongod-shard2-0.mongodb-shard2-service.default.svc.cluster.local:27017");'
kubectl exec $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval 'sh.addShard("Shard3RepSet/mongod-shard3-0.mongodb-shard3-service.default.svc.cluster.local:27017");'
sleep 2


echo "Testing replicaSets"
kubectl exec -it mongod-shard1-0 -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval "rs.status()"
kubectl exec -it mongod-shard2-0 -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval "rs.status()"
kubectl exec -it mongod-shard3-0 -- mongo --authenticationDatabase admin  --username main_admin --password abc123 --eval "rs.status()"

echo "Importing data"
kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- sh -c 'apt-get update && apt-get install -y wget ; wget https://raw.githubusercontent.com/mongodb/docs-assets/primer-dataset/primer-dataset.json ; mongoimport --db test --authenticationDatabase admin  --username main_admin --password abc123 --collection restaurants --drop --file primer-dataset.json ' 


for i in $(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.kubernetes\.io/hostname}'); do echo "Node: $i"; kubectl get pods -o wide | grep "$i"; echo "-----------------"; done  |grep -v 'hostvm' | grep -v 'configdb' | grep -v 'default-pool' |  egrep --color 'mongod-shard|^'
