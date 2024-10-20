#!/bin/bash -eu

cd "$(dirname "$0")"

cat <<EOF | kubectl apply -f -
kind: Namespace
apiVersion: v1
metadata:
  name: nginx-example-namespace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-example-deployment
  namespace: nginx-example-namespace
spec:
  selector:
    matchLabels:
      app: nginx-deployment
  replicas: 2
  template:
    metadata:
      labels:
        app: nginx-deployment
    spec:
      containers:
        - name: nginx-container
          image: nginx
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-example-service
  namespace: nginx-example-namespace
spec:
  type: LoadBalancer
  selector:
    app: nginx-deployment
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF
