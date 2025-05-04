#!/bin/bash

namespace="onify-citizen"        # default value if not set
client_instance=test             # default value if not set
client_code=onify-citizen        # default value if not set
initialLicense=SOMELICENSE       # default value if not set
ONIFY_adminUser_password="password1#AAA"
ONIFY_client_secret="VkzPJv1ZdJvIeIksqh3zfSQhkwjBJvVi/2bwHAM77tsxw"                #$(LC_ALL=C tr -dc 'A-Za-z0-9/=' </dev/urandom | head -c 45)
ONIFY_apiTokens_app_secret="=K/YN9jTePZygSsRHLp8URm2fEjAj7dgU29AUWrXYX0PHDXsUa"    #$(LC_ALL=C tr -dc 'A-Za-z0-9/=' </dev/urandom | head -c 50)
kubectl_action="apply"           # default value if not set
keyfile="keyfile.json"           # default value if not set
domain="onify.net"               # default value if not set

for arg in "$@"; do
  case $arg in
    --dry-run=true )
      dry_run_flag="--dry-run=client -o yaml"
      ;;
    --namespace=*)
      namespace="${arg#*=}"
      ;;
    --client_instance=*)
      client_instance="${arg#*=}"
      ;;
    --initialLicense=*)
      initialLicense="${arg#*=}"
      ;;
    --action=*)
      kubectl_action="${arg#*=}"
      ;;
    --keyfile=*)
      keyfile="${arg#*=}"
      ;;
    --domain=*)
      domain="${arg#*=}"
      ;;
    --adminPassword=*)
      ONIFY_adminUser_password="${arg#*=}"
      ;;
    --clientSecret=*)
      ONIFY_client_secret="${arg#*=}"
      ;;
    --appSecret=*)
      ONIFY_apiTokens_app_secret="${arg#*=}"
      ;;
  esac
done

if [[ "$action" == "delete" ]]; then
  # Remove -o yaml for delete actions
  dry_run_flag="--dry-run=client"
fi

if [[ -n "$keyfile" && -f "$keyfile" ]]; then
  keyfile_content=$(<"$keyfile")
else
  keyfile_content=""
fi



onify_namespace() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
EOF
}

onify_secrets() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: v1
data:
  .dockerconfigjson: $(echo "${keyfile_content}" | base64)
kind: Secret
metadata:
  name: onify-regcred
  namespace: ${namespace}
type: kubernetes.io/dockerconfigjson
EOF
}

onify_api() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-api 
    name: onify-api
  name: onify-api
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: onify-api
      task: onify-api
  serviceName: onify-api
  template:
    metadata:
      labels:
        app: onify-api
        task: onify-api
    spec:
      containers:
        - env:
            - name: ENV_PREFIX
              value: ONIFY_
            - name: INTERPRET_CHAR_AS_DOT
              value: _
            - name: NODE_ENV
              value: development
            - name: ONIFY_adminUser_email
              value: admin@onify.local
            - name: ONIFY_adminUser_password
              value: ${ONIFY_adminUser_password}
            - name: ONIFY_adminUser_username
              value: admin 
            - name: ONIFY_apiTokens_app_secret
              value: ${ONIFY_apiTokens_app_secret}
            - name: ONIFY_autoinstall
              value: "true"
            - name: ONIFY_client_code
              value: ${client_code}
            - name: ONIFY_client_instance
              value: ${client_instance}
            - name: ONIFY_client_secret
              value: ${ONIFY_client_secret}
            - name: ONIFY_db_indexPrefix
              value: onify
            - name: ONIFY_initialLicense
              value: ${initialLicense}
            - name: ONIFY_logging_elasticFlushInterval
              value: "500"
            - name: ONIFY_logging_log
              value: stdout,elastic
            - name: ONIFY_resources_baseDir
              value: /usr/share/onify/resources
            - name: ONIFY_resources_tempDir
              value: /usr/share/onify/temp_resources
            - name: ONIFY_worker_cleanupInterval
              value: "300"
            - name: ONIFY_db_elasticsearch_host
              value: http://onify-elasticsearch:9200
            - name: ONIFY_websockets_agent_url
              value: ws://onify-agent:8080/hub 
          image: eu.gcr.io/onify-images/hub/api:infra-node-20
          imagePullPolicy: Always
          name: onfiy-api
          ports:
            - containerPort: 8181
              name: onify-api
              protocol: TCP
      imagePullSecrets:
        - name: onify-regcred
---
apiVersion: v1
kind: Service
metadata:
  name: onify-api
  namespace: ${namespace}
spec:
  ports:
    - name: onify-api
      port: 8181
      protocol: TCP
      targetPort: 8181
  selector:
    app: onify-api
    task: onify-api
  type: ClusterIP
#---
#apiVersion: networking.k8s.io/v1
#kind: Ingress
#metadata:
#  annotations:
#    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
#    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
#  name: onify-api
#  namespace: ${namespace}
#spec:
#  ingressClassName: nginx
#  rules:
#    - host: onify-api.${domain}
#      http:
#        paths:
#          - backend:
#              service:
#                name: onify-api
#                port:
#                  number: 8181
#            pathType: ImplementationSpecific
EOF
}

onify_app() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-app
    name: onify-app
  name: onify-app
  namespace: ${namespace}
spec:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  podManagementPolicy: OrderedReady
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: onify-app
      task: onify-app
  serviceName: onify-app
  template:
    metadata:
      creationTimestamp: null
      labels:
        app: onify-app
        task: onify-app
    spec:
      containers:
        - env:
            - name: ENV_PREFIX
              value: ONIFY_
            - name: INTERPRET_CHAR_AS_DOT
              value: _
            - name: NODE_ENV
              value: production
            - name: ONIFY_api_admintoken
              value: Bearer $(echo "app:${ONIFY_apiTokens_app_secret}" | base64) 
            - name: ONIFY_api_externalUrl
              value: /api/v2
            - name: ONIFY_disableAdminEndpoints
              value: "false"
            - name: ONIFY_api_internalUrl
              value: http://onify-api:8181/api/v2
          image: eu.gcr.io/onify-images/hub/app:2.20-rc1
          imagePullPolicy: Always
          name: onfiy-api
          ports:
            - containerPort: 3000
              name: onify-app
              protocol: TCP
          resources: {}
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      enableServiceLinks: true
      imagePullSecrets:
        - name: onify-regcred
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      shareProcessNamespace: false
      terminationGracePeriodSeconds: 30
  updateStrategy:
    rollingUpdate:
      partition: 0
    type: RollingUpdate
---
apiVersion: v1
kind: Service
metadata:
  name: onify-app
  namespace: ${namespace}
spec:
  ports:
    - name: onify-app
      port: 3000
      protocol: TCP
  selector:
    app: onify-app
    task: onify-app
  type: NodePort
EOF
}

onify_helix() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-helix
    name: onify-helix
  name: onify-helix
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: onify-helix
      task: onify-helix
  serviceName: onify-helix
  template:
    metadata:
      labels:
        app: onify-helix
        task: onify-helix
    spec:
      containers:
        - env:
            - name: ONIFY_api_internalUrl
              value: http://onify-api:8181/api/v2
          image: ghcr.io/onify/helix-app-lab:latest
          imagePullPolicy: Always
          name: onfiy-helix-app
          ports:
            - containerPort: 4000
              name: onify-helix
              protocol: TCP
      imagePullSecrets:
        - name: onify-regcred
---
apiVersion: v1
kind: Service
metadata:
  name: onify-helix
  namespace: ${namespace}
spec:
  ports:
    - name: onify-helix
      port: 4000
      protocol: TCP
  selector:
    app: onify-helix
    task: onify-helix
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
  name: onify-helix
  namespace: ${namespace}
spec:
  ingressClassName: nginx
  rules:
    - host: ${namespace}.${domain}
      http:
        paths:
          - backend:
              service:
                name: onify-app
                port:
                  number: 3000
            path: /
            pathType: Prefix
          - backend:
              service:
                name: onify-helix
                port:
                  number: 4000
            path: /helix
            pathType: Prefix
EOF
}

onify_agent() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-agent
    name: onify-agent
  name: onify-agent
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: onify-agent
      task: onify-agent
  serviceName: onify-agent
  template:
    metadata:
      labels:
        app: onify-agent
        task: onify-agent
    spec:
      containers:
        - env:
            - name: hub_version
              value: v2
            - name: log_level
              value: "2"
            - name: log_type
              value: "1"
          image: eu.gcr.io/onify-images/hub/agent-server:latest
          imagePullPolicy: Always
          name: onify-agent
          ports:
            - containerPort: 8080
              name: onify-agent
              protocol: TCP
          resources: {}
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      enableServiceLinks: true
      imagePullSecrets:
        - name: onify-regcred
---
apiVersion: v1
kind: Service
metadata:
  name: onify-agent
  namespace: ${namespace}
spec:
  ports:
    - name: onify-agent
      port: 8080
      protocol: TCP
  selector:
    app: onify-agent
    task: onify-agent
  type: ClusterIP
#---
#apiVersion: networking.k8s.io/v1
#kind: Ingress
#metadata:
#  name: onify-agent
#  namespace: ${namespace}
#spec:
#  ingressClassName: nginx
#  rules:
#    - host: onify-agent.${domain}
#      http:
#        paths:
#          - backend:
#              service:
#                name: onify-agent
#                port:
#                  number: 8080
#            pathType: ImplementationSpecific
EOF
}

onify_functions() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-functions
    name: onify-functions
  name: onify-functions
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: onify-functions
      task: onify-functions
  serviceName: onify-functions
  template:
    metadata:
      labels:
        app: onify-functions
        task: onify-functions
    spec:
      containers:
        - env:
            - name: NODE_ENV
              value: production
          image: eu.gcr.io/onify-images/citizen-functions:feature-citizen-v1 
#         image: ghcr.io/onify/citizen-functions:feature-citizen-v1
          imagePullPolicy: Always
          name: onify-functions
          ports:
            - containerPort: 8282
              name: onify-functions
              protocol: TCP
      imagePullSecrets:
        - name: onify-regcred
---
apiVersion: v1
kind: Service
metadata:
  name: onify-functions
  namespace: ${namespace}
spec:
  ports:
    - name: onify-functions
      port: 8282
      protocol: TCP
  selector:
    app: onify-functions
    task: onify-functions
  type: ClusterIP
#---
#apiVersion: networking.k8s.io/v1
#kind: Ingress
#metadata:
#  name: onify-functions
#  namespace: ${namespace}
#spec:
#  ingressClassName: nginx
#  rules:
#    - host: onify-functions.${domain}
#      http:
#        paths:
#          - backend:
#              service:
#                name: onify-functions
#                port:
#                  number: 8282
#            pathType: ImplementationSpecific
EOF
}

onify_worker() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-worker
    name: onify-worker
  name: onify-worker
  namespace: ${namespace}
spec:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  podManagementPolicy: OrderedReady
  replicas: 1
  revisionHistoryLimit: 0
  selector:
    matchLabels:
      app: onify-worker
      task: onify-worker
  serviceName: onify-worker
  template:
    metadata:
      creationTimestamp: null
      labels:
        app: onify-worker
        task: onify-worker
    spec:
      automountServiceAccountToken: true
      containers:
        - args:
            - worker
          env:
            - name: ENV_PREFIX
              value: ONIFY_
            - name: INTERPRET_CHAR_AS_DOT
              value: _
            - name: NODE_ENV
              value: development
            - name: ONIFY_adminUser_email
              value: admin@onify.local
            - name: ONIFY_adminUser_password
              value: ${ONIFY_adminUser_password}
            - name: ONIFY_adminUser_username
              value: admin
            - name: ONIFY_apiTokens_app_secret
              value: ${ONIFY_apiTokens_app_secret}
            - name: ONIFY_autoinstall
              value: "true"
            - name: ONIFY_client_code
              value: ${client_code}
            - name: ONIFY_client_instance
              value: ${client_instance}
            - name: ONIFY_client_secret
              value: ${ONIFY_client_secret}
            - name: ONIFY_db_indexPrefix
              value: onify
            - name: ONIFY_initialLicense
              value: ${initialLicense}
            - name: ONIFY_logging_elasticFlushInterval
              value: "500"
            - name: ONIFY_logging_log
              value: stdout,elastic
            - name: ONIFY_resources_baseDir
              value: /usr/share/onify/resources
            - name: ONIFY_resources_tempDir
              value: /usr/share/onify/temp_resources
            - name: ONIFY_worker_cleanupInterval
              value: "300"
            - name: ONIFY_db_elasticsearch_host
              value: http://onify-elasticsearch:9200
            - name: ONIFY_websockets_agent_url
              value: ws://onify-agent:8080/hub 
          image: eu.gcr.io/onify-images/hub/api:infra-node-20
          imagePullPolicy: Always
          name: onify-worker
          ports:
            - containerPort: 8181
              name: onify-worker
              protocol: TCP
      imagePullSecrets:
        - name: onify-regcred
EOF
}

onify_elasticsearch() {
cat <<EOF | kubectl $kubectl_action $dry_run_flag -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: onify-elasticsearch
  name: onify-elasticsearch
  namespace: ${namespace}
spec:
  podManagementPolicy: Parallel
  replicas: 1
  selector:
    matchLabels:
      app: onify-elasticsearch
  serviceName: onify-elasticsearch
  template:
    metadata:
      labels:
        app: onify-elasticsearch
    spec:
      automountServiceAccountToken: true
      containers:
        - env:
            - name: discovery.type
              value: single-node
            - name: cluster.name
              value: onify-elasticsearch
            - name: ES_JAVA_OPTS
              value: -Xms1024m -Xmx1024m
          image: docker.elastic.co/elasticsearch/elasticsearch:7.16.1
          imagePullPolicy: IfNotPresent
          name: onify-elasticsearch
          ports:
            - containerPort: 9300
              name: nodes
              protocol: TCP
            - containerPort: 9200
              name: client
              protocol: TCP
          resources: {}
#         volumeMounts:
#           - mountPath: /usr/share/elasticsearch/data
#             name: onify-data
      securityContext:
        fsGroup: 2000
        runAsNonRoot: true
        runAsUser: 1000
      shareProcessNamespace: false
      terminationGracePeriodSeconds: 300
  updateStrategy:
    rollingUpdate:
      partition: 1
    type: RollingUpdate
---
apiVersion: v1
kind: Service
metadata:
  name: onify-elasticsearch
  namespace: ${namespace}
spec:
  ports:
    - name: client
      port: 9200
      protocol: TCP
    - name: nodes
      port: 9300
      protocol: TCP
  selector:
    app: onify-elasticsearch
  type: NodePort
EOF
}

onify_namespace
sleep 1
onify_secrets
onify_elasticsearch
sleep 3
onify_api
onify_agent
onify_app
onify_helix
onify_functions
onify_worker