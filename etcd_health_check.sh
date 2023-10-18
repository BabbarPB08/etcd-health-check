#!/bin/bash

# variable

etcd_pod=$(oc get pods -n openshift-etcd -l app=etcd --no-headers | tail -1 | awk '{print $1}')
data_dir="/home/core/etcd_data"
archive_name="/home/core/etcd_data.tar.gz"

pre ()
{
mkdir -p $data_dir
}

post ()
{
rm -rf $data_dir
}

pack ()
{
tar -czf "$archive_name" -C "$(dirname "$data_dir")" "$(basename "$data_dir")"
if [ $? -eq 0 ]; then
  echo "Archive created successfully: $archive_name"
else
  echo "Archive creation failed"
fi
}

etcd_table ()
{
oc rsh -n openshift-etcd $etcd_pod << EOF > $data_dir/etcd_table.logs
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

etcd_objects_count ()
{
oc rsh -n openshift-etcd $etcd_pod > $data_dir/etcd_objects_count.logs <<EOF
echo "===== ETCD Keys ====="
etcdctl get / --prefix --keys-only | grep -v ^$ | awk -F '/' '{ h[\$3]++ } END { for (k in h) print h[k], k }' | sort -nr
echo
echo "===== Events ====="
etcdctl --command-timeout=60s get --prefix --keys-only /kubernetes.io/events | awk -F/ '/./ { print \$4 }' | sort | uniq -c | sort -n
echo
echo "===== Secrets ====="
etcdctl --command-timeout=60s get --prefix --keys-only /kubernetes.io/secrets | awk -F/ '/./ { print \$4 }' | sort | uniq -c | sort -n
echo
echo "===== Pods ====="
etcdctl --command-timeout=60s get --prefix --keys-only /kubernetes.io/pods | awk -F/ '/./ { print \$4 }' | sort | uniq -c | sort -n
EOF
}

metrix ()
{
oc exec -it -c prometheus -n openshift-monitoring prometheus-k8s-0 -- curl --data-urlencode "query=histogram_quantile(0.99, sum(rate(etcd_network_peer_round_trip_time_seconds_bucket[5m])) by (le,instance))" http://localhost:9090/api/v1/query | jq ".data.result" > $data_dir/latency.out
}

obj_size ()
{
oc rsh -n openshift-etcd $etcd_pod > $data_dir/etcd_object_size.logs <<EOF
for base in kubernetes openshift; do
    readarray -t RESOURCES <<< \
        "\$(etcdctl --command-timeout=30s \
        get --prefix / --keys-only 2>/dev/null | grep -oP "(?<=/\${base}.io/).+?(?=/)" | sort | uniq)"
    for res in "\${RESOURCES[@]}"; do
        BYTES=\$(etcdctl --command-timeout=30s \
            get --prefix /\${base}.io/\$res -w protobuf | wc -c)
        COUNT=\$(etcdctl --command-timeout=30s \
            get --prefix /\${base}.io/\$res --keys-only | sed '/^$/d' | wc -l)
        echo -e "Count=\$COUNT  \tBytes=\$BYTES\tObject=/\${base}.io/\$res"
    done
done
EOF
}

pre
etcd_table
etcd_objects_count
obj_size
metrix
pack
post
