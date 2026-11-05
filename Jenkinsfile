// Simple pipeline: checkout -> build -> push to Nexus -> deploy (plain kubectl) -> ingress -> verify
pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 240, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '15'))
  }

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target namespace')
    string(name: 'IMAGE_TAG', defaultValue: '', description: 'Blank = git short SHA ("latest" is rejected)')
    string(name: 'REPLICAS', defaultValue: '1', description: 'Replicas per service')
    booleanParam(name: 'BUILD_IMAGES', defaultValue: true, description: 'Untick to redeploy an existing tag without touching images')
    booleanParam(name: 'USE_LOCAL_IMAGES', defaultValue: true, description: 'Reuse images already built on this VM (<service>:<LOCAL_TAG>) instead of rebuilding')
    string(name: 'LOCAL_TAG', defaultValue: 'optimized', description: 'Tag of the local images, e.g. adservice:optimized')
  }

  environment {
    REGISTRY     = '192.168.206.150:5000'
    REPO         = 'online-boutique'
    NAMESPACE    = "${params.ENVIRONMENT}"
    SERVICE_LIST = 'adservice cartservice checkoutservice currencyservice emailservice frontend loadgenerator paymentservice productcatalogservice recommendationservice shippingservice'
    INGRESS_PORT = '30080'
    DOCKER_CONFIG = "${WORKSPACE}/.docker"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
          env.TAG = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim() : env.GIT_SHA
          if (env.TAG == 'latest') { error('The "latest" tag is not allowed') }
          env.HOST = "shop-${params.ENVIRONMENT}.local"
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ENVIRONMENT} ${env.TAG}"
          echo "env=${params.ENVIRONMENT} tag=${env.TAG} host=${env.HOST}"
        }
      }
    }

    // Per service: already in Nexus -> skip; local image <service>:<LOCAL_TAG> exists -> tag + push (no build); otherwise build + push.
    stage('Build and Push to Nexus') {
      when { expression { params.BUILD_IMAGES } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'nexus-creds', usernameVariable: 'NX_USER', passwordVariable: 'NX_PASS')]) {
          sh '''#!/bin/bash
            set -e
            echo "$NX_PASS" | docker login ${REGISTRY} -u "$NX_USER" --password-stdin
            ACCEPT='Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
            for s in ${SERVICE_LIST}; do
              img=${REGISTRY}/${REPO}/$s:${TAG}
              if curl -sfI -u "$NX_USER:$NX_PASS" -H "$ACCEPT" "http://${REGISTRY}/v2/${REPO}/$s/manifests/${TAG}" >/dev/null; then
                echo "=== $s:${TAG} already in Nexus, skipping ==="
                continue
              fi
              if [ "${USE_LOCAL_IMAGES}" = "true" ] && docker image inspect "$s:${LOCAL_TAG}" >/dev/null 2>&1; then
                echo "=== $s: using local image $s:${LOCAL_TAG} (no rebuild) ==="
                docker tag "$s:${LOCAL_TAG}" $img
              else
                ctx="src/$s"; if [ "$s" = "cartservice" ]; then ctx="src/cartservice/src"; fi
                echo "=== build $s:${TAG} ==="
                docker build --provenance=false --label org.opencontainers.image.revision=${GIT_SHA} -t $img "$ctx"
              fi
              echo "=== push $s:${TAG} ==="
              docker push $img || { echo "retry 1"; sleep 20; docker push $img; } || { echo "retry 2"; sleep 40; docker push $img; }
              docker rmi $img >/dev/null 2>&1 || true
              free=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
              if [ "$free" -lt 6 ]; then echo "low disk (${free}G), pruning build cache"; docker builder prune -af >/dev/null; fi
            done
            docker logout ${REGISTRY}
          '''
        }
      }
    }

    stage('Deploy (Deployments + Services)') {
      steps {
        withCredentials([
          file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG'),
          usernamePassword(credentialsId: 'nexus-creds', usernameVariable: 'NX_USER', passwordVariable: 'NX_PASS')
        ]) {
          sh '''#!/bin/bash
            set -e
            kubectl get ns ${NAMESPACE} >/dev/null 2>&1 || kubectl create ns ${NAMESPACE}
            kubectl -n ${NAMESPACE} create secret docker-registry nexus-pull \
              --docker-server=${REGISTRY} --docker-username="$NX_USER" --docker-password="$NX_PASS" \
              --dry-run=client -o yaml | kubectl apply -f -

            rm -rf rendered && mkdir -p rendered
            for f in k8s/apps/*.yaml; do
              sed -e "s|__REGISTRY__|${REGISTRY}/${REPO}|g" -e "s|__TAG__|${TAG}|g" -e "s|__REPLICAS__|${REPLICAS}|g" "$f" > rendered/$(basename "$f")
            done
            if grep -rn ':latest' rendered; then echo "latest tag found"; exit 1; fi

            touch .deploy_started
            kubectl apply -n ${NAMESPACE} -f rendered/
          '''
        }
      }
    }

    stage('Ingress (Traefik)') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
          sh '''#!/bin/bash
            set -e
            kubectl get ingressclass traefik >/dev/null 2>&1 || { echo "Traefik is not installed (no IngressClass 'traefik')"; exit 1; }
            sed "s|__HOST__|${HOST}|g" k8s/ingress/ingress.yaml > rendered/ingress.yaml
            kubectl apply -n ${NAMESPACE} -f rendered/ingress.yaml
            kubectl get ingress -n ${NAMESPACE}
          '''
        }
      }
    }

    stage('Verify') {
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
          sh '''#!/bin/bash
            set -e
            for d in $(kubectl get deploy -n ${NAMESPACE} -o name); do
              kubectl rollout status $d -n ${NAMESPACE} --timeout=300s
            done
            kubectl rollout status statefulset/redis-cart -n ${NAMESPACE} --timeout=300s
            kubectl get pods -n ${NAMESPACE} -o wide
            bad=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep -Ev 'Running|Completed' || true)
            if [ -n "$bad" ]; then echo "Unhealthy pods:"; echo "$bad"; exit 1; fi

            NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
            U=http://${NODE_IP}:${INGRESS_PORT}
            H="Host: ${HOST}"
            J=$(mktemp)

            echo "1) home page through the Ingress"
            ok=0
            for i in $(seq 1 30); do
              if curl -sf -H "$H" -o /dev/null "$U/"; then ok=1; break; fi
              sleep 5
            done
            [ $ok -eq 1 ] || { echo "Ingress did not answer at $U with Host ${HOST}"; exit 1; }
            echo "2) product page";  curl -sf -H "$H" -o /dev/null "$U/product/OLJCESPC7Z"
            echo "3) add to cart";   curl -sf -L -H "$H" -c $J -b $J -o /dev/null -d "product_id=OLJCESPC7Z&quantity=1" "$U/cart"
            echo "4) checkout"
            curl -sf -L -H "$H" -c $J -b $J -d "email=ci@example.com&street_address=1 Main St&zip_code=94043&city=Mountain View&state=CA&country=United States&credit_card_number=4432801561520454&credit_card_expiration_month=1&credit_card_expiration_year=2030&credit_card_cvv=672" \
              "$U/cart/checkout" | grep -qi "order is complete"
            echo "Verification passed: curl -H 'Host: ${HOST}' $U/"
          '''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'rendered/**', allowEmptyArchive: true
      sh '''#!/bin/bash
        rm -rf ${DOCKER_CONFIG}
        docker image prune -f >/dev/null 2>&1 || true
      '''
    }
    failure {
      script {
        // roll back only if we had already touched the cluster
        if (fileExists('.deploy_started')) {
          withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
            sh '''#!/bin/bash
              echo "AUTO-ROLLBACK in ${NAMESPACE}"
              for d in $(kubectl get deploy -n ${NAMESPACE} -o name 2>/dev/null); do
                kubectl rollout undo $d -n ${NAMESPACE} || true
              done
            '''
          }
        }
        echo "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER} ${env.BUILD_URL}"
      }
    }
    success { echo "SUCCESS: ${params.ENVIRONMENT} runs ${env.TAG}" }
  }
}
