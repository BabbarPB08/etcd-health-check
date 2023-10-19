#!/bin/bash

# Variables
etcd_pod=$(oc get pods -n openshift-etcd -l app=etcd --no-headers | tail -1 | awk '{print $1}')
data_dir="/tmp/etcd_data"
archive_name="/tmp/etcd_data.tar.gz"

# Function to create the directory structure
pre() {
  mkdir -p "$data_dir"
}

# Function to remove the directory
post() {
  rm -rf "$data_dir"
}

# Function to pack data into a tar.gz archive
pack() {
  tar -czf "$archive_name" -C "$(dirname "$data_dir")" "$(basename "$data_dir")"
  if [ $? -eq 0 ]; then
    echo "Archive created successfully: $archive_name"
  else
    echo "Archive creation failed"
  fi
}

# Function to display etcd member information
etcd_table() {
  oc rsh -n openshift-etcd "$etcd_pod" <<EOF
    echo "---------- Member List ----------"
    etcdctl member list -w table
    echo "------------------------------------------------------------"
    echo "---------- Endpoint Health ----------"
    etcdctl endpoint health -w table
    etcdctl endpoint health --cluster
    echo "------------------------------------------------------------"
    echo "---------- Endpoint Status ----------"
    etcdctl endpoint status -w table
EOF
}

# Function to count etcd objects
etcd_objects_count() {
  echo -e "\n===== \nETCD Keys \n=====" 
  oc rsh -n openshift-etcd "$etcd_pod" bash -c "etcdctl --command-timeout=60s get / --prefix --keys-only | sed '/^$/d' | cut -d/ -f3 | sort | uniq -c | sort -rn && exit 0"
  echo -e "\n\n\n======= \nEvents \n=======" 
  oc rsh -n openshift-etcd "$etcd_pod" bash -c "etcdctl --command-timeout=60s get --prefix --keys-only /kubernetes.io/events | awk -F/ '/./ { print \$4 }' | sort | uniq -c | sort -rn && exit 0"
  echo -e "\n\n\n====== \nSecrets \n======" 
  oc rsh -n openshift-etcd "$etcd_pod" bash -c "etcdctl --command-timeout=60s get --prefix --keys-only /kubernetes.io/secrets | awk -F/ '/./ { print \$4 }' | sort | uniq -c | sort -rn && exit 0"
  echo -e "\n\n\n======= \nPods \n=======" 
  oc rsh -n openshift-etcd "$etcd_pod" bash -c "etcdctl --command-timeout=60s get --prefix --keys-only /kubernetes.io/pods | awk -F/ '/./ { print \$4 }' | sort | uniq -c | sort -rn && exit 0"
}

# Function to display etcd network latency metrics
metrix() {
  oc exec -it -c prometheus -n openshift-monitoring prometheus-k8s-0 -- curl --data-urlencode "query=histogram_quantile(0.99, sum(rate(etcd_network_peer_round_trip_time_seconds_bucket[5m])) by (le,instance))" http://localhost:9090/api/v1/query | jq ".data.result"
}

# Function to calculate the size of etcd objects
obj_size() {
  oc rsh -n openshift-etcd "$etcd_pod" <<EOF
    for base in kubernetes openshift; do
      readarray -t RESOURCES <<< "$(etcdctl --command-timeout=30s get --prefix / --keys-only 2>/dev/null | grep -oP "(?<=/\${base}.io/).+?(?=/)" | sort | uniq)"
      for res in "\${RESOURCES[@]}"; do
        BYTES=\$(etcdctl --command-timeout=30s get --prefix /\${base}.io/\$res -w protobuf | wc -c)
        COUNT=\$(etcdctl --command-timeout=30s get --prefix /\${base}.io/\$res --keys-only | sed '/^$/d' | wc -l)
        echo -e "Count=\$COUNT  \tBytes=\$BYTES\tObject=/\${base}.io/\$res"
      done
    done
EOF
}

# Main script (function calling)
pre
etcd_table > "$data_dir/etcd_table.log"
etcd_objects_count &> "$data_dir/etcd_objects_count.log"
obj_size &> "$data_dir/etcd_objects_size.log"
metrix &> "$data_dir/latency.log"
pack
post
