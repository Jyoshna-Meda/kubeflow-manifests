#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
# ---------------------------------------------
# Script to deploy cert-manager, Istio, and oauth2-proxy
# Only proceeds if all Pods in each namespace are Running & Ready
# ---------------------------------------------

MAX_RETRIES=3
RETRY_DELAY=10

# Function to print step headers
print_step() {
  echo
  echo "🔹 STEP $1: $2"
  echo "-----------------------------------------"
}

# Function to check if all pods in a namespace are Running and Ready
check_all_pods_running() {
  local ns=$1
  echo "🔍 Checking if all pods in namespace '$ns' are Running and Ready..."

  local timeout=180
  local interval=5
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    not_ready=$(kubectl get pods -n $ns --no-headers 2>/dev/null | awk '{print $1}' | \
      xargs -I {} kubectl get pod {} -n $ns -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | \
      tr ' ' '\n' | grep -cv true)

    if [ "$not_ready" -eq 0 ]; then
      echo "✅ All pods in namespace '$ns' are Running and Ready!"
      return 0
    fi

    echo "⏳ Waiting... ($elapsed / $timeout seconds)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "❌ Timeout: Not all pods in namespace '$ns' are ready."
  return 1
}

# -------------------------------
# STEP 1: Deploy cert-manager
# -------------------------------
CERT_NS=cert-manager
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for cert-manager"
  echo "========================================="

  print_step 1 "Installing cert-manager base manifests"
  if ! kustomize build common/cert-manager/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 2 "Installing Kubeflow issuer manifests"
  if ! kustomize build common/cert-manager/kubeflow-issuer/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 3 "Waiting for cert-manager Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pod -l 'app in (cert-manager,webhook)' --timeout=180s -n $CERT_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 4 "Checking cert-manager Pod Status (Running + Ready)"
  if ! check_all_pods_running $CERT_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ cert-manager fully deployed and healthy!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy cert-manager after $MAX_RETRIES attempts."
  exit 1
fi

# -------------------------------
# STEP 2: Deploy Istio with external auth
# -------------------------------
ISTIO_NS=istio-system
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Istio"
  echo "========================================="

  print_step 5 "Installing Istio configured with external authorization"
  if ! kustomize build common/istio-1-24/istio-crds/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  if ! kustomize build common/istio-1-24/istio-namespace/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  if ! kustomize build common/istio-1-24/istio-install/overlays/oauth2-proxy | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 6 "Waiting for all Istio Pods to become ready"
  if ! kubectl wait --for=condition=Ready pods --all -n $ISTIO_NS --timeout=300s; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 7 "Checking Istio Pod Status (Running + Ready)"
  if ! check_all_pods_running $ISTIO_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Istio fully deployed and healthy!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Istio after $MAX_RETRIES attempts."
  exit 1
fi

# -------------------------------
# STEP 3: Deploy oauth2-proxy
# -------------------------------
OAUTH_NS=oauth2-proxy
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for oauth2-proxy"
  echo "========================================="

  print_step 8 "Installing oauth2-proxy (m2m-dex-only overlay)"
  if ! kustomize build common/oauth2-proxy/overlays/m2m-dex-only/ | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 9 "Waiting for oauth2-proxy Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pod -l 'app.kubernetes.io/name=oauth2-proxy' --timeout=180s -n $OAUTH_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 10 "Checking oauth2-proxy Pod Status (Running + Ready)"
  if ! check_all_pods_running $OAUTH_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ oauth2-proxy fully deployed and healthy!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy oauth2-proxy after $MAX_RETRIES attempts."
  exit 1
fi

echo
echo "🎉 All components deployed successfully: cert-manager, Istio, and oauth2-proxy"
echo "🚀 Ready for the next namespace installation!"


============================================================

# -------------------------------
# STEP 4: Deploy Dex
# -------------------------------
DEX_NS=auth
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Dex"
  echo "========================================="

  print_step 11 "Installing Dex with oauth2-proxy overlay"
  if ! kustomize build common/dex/overlays/oauth2-proxy | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 12 "Waiting for all Dex Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pods --all --timeout=180s -n $DEX_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 13 "Checking Dex Pod Status (Running + Ready)"
  if ! check_all_pods_running $DEX_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Dex fully deployed and healthy!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Dex after $MAX_RETRIES attempts."
  exit 1
fi

===============================================================================

# -------------------------------
# STEP 5: Install Knative Serving with Istio Gateway
# -------------------------------
KNA_NS=knative-serving
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Knative Serving and Istio Gateway"
  echo "========================================="

  print_step 14 "Installing Knative Serving with Istio Gateway"
  if ! kustomize build common/knative/knative-serving/overlays/gateways | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 15 "Installing Istio Cluster Local Gateway"
  if ! kustomize build common/istio-1-24/cluster-local-gateway/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 16 "Waiting for all Knative Serving Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pods --all --timeout=180s -n $KNA_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 17 "Checking Knative Serving Pods Status (Running + Ready)"
  if ! check_all_pods_running $KNA_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Knative Serving and Istio Gateway deployed and healthy!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Knative Serving and Istio Gateway after $MAX_RETRIES attempts."
  exit 1
fi

# -------------------------------
# STEP 6: Install Knative Eventing
# -------------------------------
EVENT_NS=knative-eventing
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Knative Eventing"
  echo "========================================="

  print_step 18 "Installing Knative Eventing"
  if ! kustomize build common/knative/knative-eventing/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 19 "Waiting for all Knative Eventing Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pods --all --timeout=180s -n $EVENT_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 20 "Checking Knative Eventing Pods Status (Running + Ready)"
  if ! check_all_pods_running $EVENT_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Knative Eventing deployed and healthy!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Knative Eventing after $MAX_RETRIES attempts."
  exit 1
fi
============================================================================================
# -------------------------------
# STEP 7: Apply Kubeflow Namespace and Common Resources
# -------------------------------
print_step 21 "Creating Kubeflow Namespace"
kustomize build common/kubeflow-namespace/base | kubectl apply -f -

print_step 22 "Applying Network Policies"
kustomize build common/networkpolicies/base | kubectl apply -f -

print_step 23 "Applying Kubeflow Roles"
kustomize build common/kubeflow-roles/base | kubectl apply -f -

print_step 24 "Applying Kubeflow Istio Resources"
kustomize build common/istio-1-24/kubeflow-istio-resources/base | kubectl apply -f -

echo "✅ Kubeflow base configurations applied (no pods expected)"
==================================================================================================

# -------------------------------
# STEP 8: Install Kubeflow Pipelines (Multi-User, Cert-Manager)
# -------------------------------
PIPELINE_NS=kubeflow
attempt=1

while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Pipelines Metadata Components"
  echo "==============================================================="

  print_step 25 "Installing Kubeflow Pipelines (Multi-User Cert-Manager overlay)"
  if ! kustomize build apps/pipeline/upstream/env/cert-manager/platform-agnostic-multi-user | kubectl apply -f -; then
    attempt=$((attempt+1))
    sleep $RETRY_DELAY
    continue
  fi

  print_step 26 "Waiting for Pipelines Pods to become Ready (timeout 300s)"
  if ! kubectl wait --for=condition=Ready pods --all -n $PIPELINE_NS --timeout=400s; then
    echo "⚠️ Not all pods became ready. Attempting to fix MySQL metadata DB if needed..."

    MYSQL_POD=$(kubectl get pods -n $PIPELINE_NS -o name | grep '^pod/mysql' | head -n1)
    if [ -n "$MYSQL_POD" ]; then
      echo "🔍 Entering MySQL pod: $MYSQL_POD"

      TABLE_COUNT=0
      fix_attempt=1
      while [ "$TABLE_COUNT" -ne 16 ]; do
        echo "🔁 MySQL Fix Attempt $fix_attempt: Checking for exactly 15 tables..."

        TABLE_COUNT=$(kubectl exec -n $PIPELINE_NS $MYSQL_POD -- \
          mysql -u root -p'' -e "USE metadb; SHOW TABLES;" 2>/dev/null | wc -l)

        if [ "$TABLE_COUNT" -ne 16 ]; then
          echo "❌ metadb has incorrect number of tables ($((TABLE_COUNT - 1))). Recreating metadb..."
          kubectl exec -n $PIPELINE_NS $MYSQL_POD -- \
            mysql -u root -p'' -e "DROP DATABASE IF EXISTS metadb; CREATE DATABASE metadb;"

          echo "♻️ Deleting metadata-grpc and metadata-writer pods..."
          GRPC_POD=$(kubectl get pods -n $PIPELINE_NS -o name | grep metadata-grpc | head -n1)
          WRITER_POD=$(kubectl get pods -n $PIPELINE_NS -o name | grep metadata-writer | head -n1)

          [ -n "$GRPC_POD" ] && kubectl delete $GRPC_POD -n $PIPELINE_NS
          [ -n "$WRITER_POD" ] && kubectl delete $WRITER_POD -n $PIPELINE_NS

          echo "⏳ Waiting for 140s before rechecking..."
          sleep 140
          fix_attempt=$((fix_attempt + 1))
        else
          echo "✅ metadb has exactly 15 tables. Proceeding..."

          # Now entering MySQL pod to run the necessary command
          kubectl exec -n $PIPELINE_NS $MYSQL_POD -- \
            mysql -u root -p'' -e "USE metadb; INSERT INTO MLMDEnv (schema_version) VALUES (10);"

          echo "✅ Inserted schema_version 10 into MLMDEnv table."

          # Exiting the MySQL pod
          kubectl exec -n $PIPELINE_NS $MYSQL_POD -- exit

          # Deleting the metadata-grpc pod
          echo "♻️ Deleting metadata-grpc pod..."
          GRPC_POD=$(kubectl get pods -n $PIPELINE_NS -o name | grep metadata-grpc | head -n1)
          [ -n "$GRPC_POD" ] && kubectl delete $GRPC_POD -n $PIPELINE_NS

          break
        fi
      done
    fi

    sleep $RETRY_DELAY
    attempt=$((attempt+1))
    continue
  fi

  print_step 27 "Verifying all Pipelines Pods are Running and Ready"
  if ! check_all_pods_running $PIPELINE_NS; then
    attempt=$((attempt+1))
    sleep $RETRY_DELAY
    continue
  fi

  echo "✅ Kubeflow Pipelines deployed and verified!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Kubeflow Pipelines metadata after $MAX_RETRIES attempts."
  exit 1
fi
=========================================================

# -------------------------------
# STEP 5: Deploy KServe
# -------------------------------
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for KServe"
  echo "=========================================="

  print_step 14 "Installing KServe"
  if ! kustomize build apps/kserve/kserve | kubectl apply --server-side --force-conflicts -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 15 "Waiting for KServe Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pods --all --timeout=300s -n $PIPELINE_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 16 "Checking KServe Pod Status"
  if ! check_all_pods_running $PIPELINE_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ KServe deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy KServe after $MAX_RETRIES attempts."
  exit 1
fi

# -------------------------------
# STEP 6: Deploy Models Web App
# -------------------------------
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Models Web App"
  echo "==================================================="

  print_step 17 "Installing Models Web App"
  if ! kustomize build apps/kserve/models-web-app/overlays/kubeflow | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 18 "Waiting for Models Web App Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pods --all --timeout=180s -n $PIPELINE_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 19 "Checking Models Web App Pod Status"
  if ! check_all_pods_running $PIPELINE_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Models Web App deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Models Web App after $MAX_RETRIES attempts."
  exit 1
fi
=========================================================================================

# -------------------------------
# STEP 7: Deploy Katib
# -------------------------------
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Katib"
  echo "=========================================="

  print_step 20 "Installing Katib"
  if ! kustomize build apps/katib/upstream/installs/katib-with-kubeflow | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  print_step 21 "Waiting for Katib Pods to become Ready"
  if ! kubectl wait --for=condition=Ready pods --all --timeout=300s -n $PIPELINE_NS; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Katib deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Katib after $MAX_RETRIES attempts."
  exit 1
fi
============================================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Central Dashboard"
  echo "========================================================"

  print_step 23 "Installing Central Dashboard with oauth2-proxy overlay"
  if ! kustomize build apps/centraldashboard/overlays/oauth2-proxy | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Central Dashboard deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Central Dashboard after $MAX_RETRIES attempts."
  exit 1
fi
============================================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Admission Webhook"
  echo "========================================================="

  print_step 24 "Installing Admission Webhook with cert-manager overlay"
  if ! kustomize build apps/admission-webhook/upstream/overlays/cert-manager | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Admission Webhook deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Admission Webhook after $MAX_RETRIES attempts."
  exit 1
fi
============================================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Jupyter Notebook Controller"
  echo "==================================================================="

  print_step 28 "Installing Jupyter Notebook Controller"
  if ! kustomize build apps/jupyter/notebook-controller/upstream/overlays/kubeflow | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Jupyter Notebook Controller deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Jupyter Notebook Controller after $MAX_RETRIES attempts."
  exit 1
fi
===========================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Jupyter Web App"
  echo "======================================================="

  print_step 29 "Installing Jupyter Web App"
  if ! kustomize build apps/jupyter/jupyter-web-app/upstream/overlays/istio | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Jupyter Web App deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Jupyter Web App after $MAX_RETRIES attempts."
  exit 1
fi
===================================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for PVC Viewer Controller"
  echo "=============================================================="

  print_step 30 "Installing PVC Viewer Controller"
  if ! kustomize build apps/pvcviewer-controller/upstream/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ PVC Viewer Controller deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy PVC Viewer Controller after $MAX_RETRIES attempts."
  exit 1
fi
=================================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Profiles"
  echo "==============================================="

  print_step 31 "Installing Profiles"
  if ! kustomize build apps/profiles/upstream/overlays/kubeflow | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Profiles deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Profiles after $MAX_RETRIES attempts."
  exit 1
fi
=================================================================================

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Volumes Web App"
  echo "==============================================="

  print_step 32 "Installing Volumes Web App"
  if ! kustomize build apps/volumes-web-app/upstream/overlays/istio | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Volumes Web App deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Volumes Web App after $MAX_RETRIES attempts."
  exit 1
fi
===================================================================================

# TensorBoard Web App
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for TensorBoard Web App"
  echo "================================================="

  print_step 33 "Installing TensorBoard Web App"
  if ! kustomize build apps/tensorboard/tensorboards-web-app/upstream/overlays/istio | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ TensorBoard Web App deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy TensorBoard Web App after $MAX_RETRIES attempts."
  exit 1
fi

# TensorBoard Controller
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for TensorBoard Controller"
  echo "===================================================="

  print_step 34 "Installing TensorBoard Controller"
  if ! kustomize build apps/tensorboard/tensorboard-controller/upstream/overlays/kubeflow | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ TensorBoard Controller deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy TensorBoard Controller after $MAX_RETRIES attempts."
  exit 1
fi
====================================================================================

# Training Operator
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for Training Operator"
  echo "===================================================="

  print_step 35 "Installing Training Operator"
  if ! kustomize build apps/training-operator/upstream/overlays/kubeflow | kubectl apply --server-side --force-conflicts -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ Training Operator deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy Training Operator after $MAX_RETRIES attempts."
  exit 1
fi
=========================================================================================

# User Namespace
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  echo
  echo "🔁 Attempt $attempt of $MAX_RETRIES for User Namespace"
  echo "===================================================="

  print_step 40 "Installing User Namespace"
  if ! kustomize build common/user-namespace/base | kubectl apply -f -; then
    attempt=$((attempt+1)); sleep $RETRY_DELAY; continue
  fi

  echo "✅ User Namespace deployed successfully!"
  break
done

if [ $attempt -gt $MAX_RETRIES ]; then
  echo "❌ Failed to deploy User Namespace after $MAX_RETRIES attempts."
  exit 1
fi
=========================================================================================

# Check the status of katib-mysql pod
KATIB_MYSQL_POD=$(kubectl get pods -n $PIPELINE_NS | grep katib-mysql | awk '{print $1}')
if [ -n "$KATIB_MYSQL_POD" ]; then
  POD_STATUS=$(kubectl get pod $KATIB_MYSQL_POD -n $PIPELINE_NS -o jsonpath='{.status.containerStatuses[0].ready}')
  if [ "$POD_STATUS" != "true" ]; then
    echo "⚠️ katib-mysql pod is in a problematic state (0/1 container status). Deleting and reapplying Katib..."

    # Delete the existing Katib deployment and reapply it
    kustomize build apps/katib/upstream/installs/katib-with-kubeflow | kubectl delete -f -
    kustomize build apps/katib/upstream/installs/katib-with-kubeflow | kubectl apply -f -
  fi
fi

