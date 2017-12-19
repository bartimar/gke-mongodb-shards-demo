#!/bin/bash

source cluster.conf
echo "Backuping cluster"

read -r -d '' CMD << END
sh.status();
sh.stopBalancer();
sh.startBalancer();
END
echo "Executing:"
echo "$CMD"

kubectl exec -it $(kubectl get pod -l "tier=routers" -o jsonpath='{.items[0].metadata.name}') -c mongos-container -- mongo --authenticationDatabase admin  --username "$MONGO_USER" --password "$MONGO_PASSWORD" --eval "$CMD"
