all: TODO

CLUSTER_SIZE := 100
NODE_NUMBERS := $(shell seq -f '%02.0f' 1 ${CLUSTER_SIZE})
LOG_RETRIEVAL_TARGETS := $(addprefix job,${NODE_NUMBERS})
NODE_NAMES := $(addprefix kube-scale-,${NODE_NUMBERS})

kubectl:
	wget http://storage.googleapis.com/kubernetes-release/release/v1.1.2/bin/linux/amd64/kubectl
	chmod +x kubectl

calicoctl:
	wget http://www.projectcalico.org/builds/calicoctl
	chmod +x calicoctl

deploy-heapster: remove-heapster
	kubectl create -f heapster

remove-heapster:
	-kubectl delete service monitoring-grafana --grace-period=1 --namespace=kube-system
	-kubectl delete service monitoring-influxdb --grace-period=1 --namespace=kube-system
	-kubectl delete service heapster --grace-period=1 --namespace=kube-system
	-kubectl delete rc heapster --grace-period=1 --namespace=kube-system
	-kubectl delete rc influxdb-grafana --grace-period=1 --namespace=kube-system

# Node selectors in the pod specs don't allow negation, so apply a label that can be used as-is here.
# TODO - add a rety in here as the kubectl label nodes doesn't do them all.
apply-node-labels:
	bash -c 'while [ $$(kubectl get no |grep role=node -c) -ne ${CLUSTER_SIZE} ] ;  do kubectl label nodes -l kubernetes.io/hostname!=127.0.0.1 role=node; done'
	kubectl get no
	@echo "Number of labeled nodes: "
	@make --no-print-directory gce-list-nodes-count

deploy-pinger: remove-pinger
	kubectl create -f pinger
	kubectl get rc
	kubectl get po

remove-pinger:
	-kubectl delete rc pinger --grace-period=1

scale-pinger:
	kubectl scale --replicas=10000 rc/pinger

# See http://stackoverflow.com/a/12110773/61318
#make -j12 CLUSTER_SIZE=26 pull-plugin-timings
pull-plugin-timings: ${LOG_RETRIEVAL_TARGETS}
	cat timings/*.log > timings/all.timings

${LOG_RETRIEVAL_TARGETS}: job%:
	@mkdir -p timings
	@ssh -o LogLevel=quiet core@kube-scale-master.us-central1-a.unique-caldron-775 ssh -o LogLevel=quiet -o StrictHostKeyChecking=no kube-scale-$* grep TIMING  /var/log/calico/cni/cni.log > timings/calico-$*.log

.PHONEY: ${LOG_RETRIEVAL_TARGETS}

gce-create: kubectl calicoctl
	-gcloud compute instances create \
  	kube-scale-master \
  	--image-project coreos-cloud \
  	--image coreos-alpha-899-1-0-v20151218 \
  	--machine-type n1-highcpu-16 \
  	--local-ssd interface=scsi \
  	--metadata-from-file user-data=master-config-template.yaml

	gcloud compute instances create \
  	${NODE_NAMES} \
  	--image-project coreos-cloud \
  	--image coreos-alpha-899-1-0-v20151218 \
  	--machine-type n1-highcpu-2 \
  	--metadata-from-file user-data=node-config-template.yaml \
  	--no-address \
  	--preemptible \
  	--tags no-ip

	make gce-config-ssh

gce-cleanup:
	gcloud compute instances list -r 'kube-scale.*' |tail -n +2 |cut -f1 -d' ' |xargs gcloud compute instances delete

gce-forward-ports:
	@-pkill -f '8080:localhost:8080'
	bash -c 'until ssh -o LogLevel=quiet -o PasswordAuthentication=no core@kube-scale-master.us-central1-a.unique-caldron-775 date; do echo "Try again"; done'
	ssh -o PasswordAuthentication=no -L 8080:localhost:8080 -L 2379:localhost:2379 -L 4194:localhost:4194 -o LogLevel=quiet -nNT core@kube-scale-master.us-central1-a.unique-caldron-775 &

gce-redeploy:
	gcloud compute instances add-metadata kube-scale-master --metadata-from-file=user-data=master-config-template.yaml
	gcloud compute instances add-metadata ${NODE_NAMES} --metadata-from-file=user-data=node-config-template.yaml
#	gcloud compute ssh kube-scale-master sudo reboot

gce-config-ssh:
	gcloud compute config-ssh

gce-ssh-master:
	ssh core@kube-scale-master.us-central1-a.unique-caldron-775

gce-bgp-status:
	ssh core@kube-scale-master.us-central1-a.unique-caldron-775 /opt/bin/calicoctl status

gce-bgp-status-count:
	ssh core@kube-scale-master.us-central1-a.unique-caldron-775 /opt/bin/calicoctl status |grep -c Established

gce-list-nodes:
	kubectl get no --no-headers -l 'kubernetes.io/hostname!=127.0.0.1'

gce-list-nodes-count:
	@kubectl get no --no-headers -l 'kubernetes.io/hostname!=127.0.0.1' | wc -l

gce-successful-pods:
	kubectl get po | grep -P -c '1/1\s+Running\s+0'