// Online Boutique CI/CD: checkout -> validate -> Sonar -> build -> Trivy -> Nexus -> Helm deploy -> verify -> smoke -> auto rollback
def SERVICES_ALL = ['adservice','cartservice','checkoutservice','currencyservice','emailservice','frontend',
                    'loadgenerator','paymentservice','productcatalogservice','recommendationservice','shippingservice']

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 240, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'staging', 'prod'], description: 'Target environment (namespace)')
    string(name: 'IMAGE_TAG', defaultValue: '', description: 'Blank = git short SHA. To promote an existing tag, set it and untick BUILD_IMAGES. "latest" is rejected.')
    string(name: 'SERVICES', defaultValue: 'all', description: 'all, or comma list (subset is only allowed when DEPLOY is unticked)')
    booleanParam(name: 'BUILD_IMAGES', defaultValue: true, description: 'Build, scan and push images')
    booleanParam(name: 'RUN_SONAR', defaultValue: true, description: 'Run SonarQube analysis')
    booleanParam(name: 'ENFORCE_QUALITY_GATE', defaultValue: false, description: 'Fail the build if the Sonar quality gate fails (needs the Sonar webhook)')
    choice(name: 'TRIVY_SEVERITY', choices: ['CRITICAL', 'HIGH,CRITICAL'], description: 'Fail the build on these severities')
    booleanParam(name: 'DEPLOY', defaultValue: true, description: 'Deploy to Kubernetes')
    string(name: 'NOTIFY_EMAIL', defaultValue: '', description: 'Optional e-mail for notifications (needs SMTP configured in Jenkins)')
  }

  environment {
    REGISTRY  = '192.168.206.150:5000'
    REPO      = 'online-boutique'
    CHART     = 'deploy/online-boutique'
    RELEASE   = 'online-boutique'
    NAMESPACE = "${params.ENVIRONMENT}"
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

          def list = params.SERVICES.trim() == 'all' ? SERVICES_ALL : params.SERVICES.split(',').collect { it.trim() }
          def unknown = list.findAll { !(it in SERVICES_ALL) }
          if (unknown) { error("Unknown services: ${unknown}") }
          if (params.DEPLOY && list.size() != SERVICES_ALL.size()) {
            error('Deploying needs SERVICES=all. Untick DEPLOY to build a subset.')
          }
          env.SELECTED = list.join(' ')
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ENVIRONMENT} ${env.TAG}"
          echo "Env=${params.ENVIRONMENT} Tag=${env.TAG} Services=${env.SELECTED}"
        }
      }
    }

    stage('Validate') {
      steps {
        sh '''#!/bin/bash
          set -e
          mkdir -p reports
          for s in ${SELECTED}; do
            ctx="src/$s"; if [ "$s" = "cartservice" ]; then ctx="src/cartservice/src"; fi
            test -f "$ctx/Dockerfile" || { echo "Missing $ctx/Dockerfile"; exit 1; }
          done
          helm lint ${CHART} -f ${CHART}/values-${ENVIRONMENT}.yaml --set global.tag=${TAG}
          helm template ${RELEASE} ${CHART} -n ${NAMESPACE} -f ${CHART}/values-${ENVIRONMENT}.yaml \
            --set global.tag=${TAG} > reports/rendered-${ENVIRONMENT}.yaml
          if grep -nE 'image:.*:latest' reports/rendered-${ENVIRONMENT}.yaml; then
            echo "Found a :latest image"; exit 1
          fi
          echo "Validation OK"
        '''
      }
    }

    stage('SonarQube Analysis') {
      when { expression { params.RUN_SONAR } }
      steps {
        script {
          def scannerHome = tool 'sonar-scanner'
          withSonarQubeEnv('sonarqube') {
            sh """${scannerHome}/bin/sonar-scanner \
              -Dsonar.projectKey=online-boutique \
              -Dsonar.projectName='Online Boutique' \
              -Dsonar.projectVersion=${env.TAG} \
              -Dsonar.sources=src \
              -Dsonar.java.binaries=. \
              -Dsonar.exclusions='**/node_modules/**,**/genproto/**,**/*.pb.go,**/*_pb2*.py,**/vendor/**,**/bin/**,**/obj/**,**/*.js,**/*.ts,**/*.css'"""
          }
        }
      }
    }

    stage('Quality Gate') {
      when { expression { params.RUN_SONAR && params.ENFORCE_QUALITY_GATE } }
      steps {
        timeout(time: 10, unit: 'MINUTES') { waitForQualityGate abortPipeline: true }
      }
    }

    stage('Docker Build') {
      when { expression { params.BUILD_IMAGES } }
      steps {
        sh '''#!/bin/bash
          set -e
          for s in ${SELECTED}; do
            ctx="src/$s"; if [ "$s" = "cartservice" ]; then ctx="src/cartservice/src"; fi
            echo "=== build $s:${TAG} ==="
            docker build --label org.opencontainers.image.revision=${GIT_SHA} \
              -t ${REGISTRY}/${REPO}/$s:${TAG} "$ctx"
            docker builder prune -f >/dev/null
          done
        '''
      }
    }

    stage('Trivy Scan') {
      when { expression { params.BUILD_IMAGES } }
      steps {
        sh '''#!/bin/bash
          mkdir -p reports; fail=0
          for s in ${SELECTED}; do
            echo "=== trivy $s ==="
            trivy image --scanners vuln --severity ${TRIVY_SEVERITY} --ignore-unfixed --no-progress \
              --exit-code 1 --format table -o reports/trivy-$s.txt ${REGISTRY}/${REPO}/$s:${TAG} || fail=1
            cat reports/trivy-$s.txt
          done
          if [ $fail -ne 0 ]; then echo "Vulnerabilities at ${TRIVY_SEVERITY} found, blocking push"; exit 1; fi
        '''
      }
    }

    stage('Push to Nexus') {
      when { expression { params.BUILD_IMAGES } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'nexus-creds', usernameVariable: 'NX_USER', passwordVariable: 'NX_PASS')]) {
          sh '''#!/bin/bash
            set -e
            echo "$NX_PASS" | docker login ${REGISTRY} -u "$NX_USER" --password-stdin
            for s in ${SELECTED}; do docker push ${REGISTRY}/${REPO}/$s:${TAG}; done
            docker logout ${REGISTRY}
          '''
        }
      }
    }

    stage('Deploy') {
      when { expression { params.DEPLOY } }
      steps {
        script {
          if (params.ENVIRONMENT == 'prod') {
            timeout(time: 30, unit: 'MINUTES') { input message: "Deploy ${env.TAG} to PRODUCTION?", ok: 'Deploy' }
          }
        }
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

            helm history ${RELEASE} -n ${NAMESPACE} --max 1 -o json 2>/dev/null | jq -r '.[0].revision // empty' > .prev_revision || true
            echo "previous revision: $(cat .prev_revision)"
            touch .deploy_started

            helm upgrade --install ${RELEASE} ${CHART} -n ${NAMESPACE} \
              -f ${CHART}/values-${ENVIRONMENT}.yaml \
              --set global.tag=${TAG} \
              --wait --timeout 10m --history-max 10
          '''
        }
      }
    }

    stage('Verify Deployment') {
      when { expression { params.DEPLOY } }
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
          sh '''#!/bin/bash
            set -e
            for d in $(kubectl get deploy -n ${NAMESPACE} -l app.kubernetes.io/instance=${RELEASE} -o name); do
              kubectl rollout status $d -n ${NAMESPACE} --timeout=300s
            done
            kubectl rollout status statefulset/redis-cart -n ${NAMESPACE} --timeout=300s
            kubectl get pods -n ${NAMESPACE} -o wide
            bad=$(kubectl get pods -n ${NAMESPACE} --no-headers | grep -Ev 'Running|Completed' || true)
            if [ -n "$bad" ]; then echo "Unhealthy pods:"; echo "$bad"; exit 1; fi
          '''
        }
      }
    }

    stage('Smoke Test') {
      when { expression { params.DEPLOY } }
      steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
          sh '''#!/bin/bash
            set -e
            PORT=$((20000 + BUILD_NUMBER % 1000))
            kubectl port-forward -n ${NAMESPACE} svc/frontend ${PORT}:80 >/tmp/pf-${BUILD_NUMBER}.log 2>&1 &
            PF=$!
            trap "kill $PF 2>/dev/null || true" EXIT
            sleep 5
            U=http://127.0.0.1:${PORT}
            J=$(mktemp)

            echo "1) home page";     curl -sf -o /dev/null "$U/"
            echo "2) product page";  curl -sf -o /dev/null "$U/product/OLJCESPC7Z"
            echo "3) add to cart";   curl -sf -L -c $J -b $J -o /dev/null -d "product_id=OLJCESPC7Z&quantity=1" "$U/cart"
            echo "4) checkout"
            curl -sf -L -c $J -b $J -d "email=ci@example.com&street_address=1 Main St&zip_code=94043&city=Mountain View&state=CA&country=United States&credit_card_number=4432801561520454&credit_card_expiration_month=1&credit_card_expiration_year=2030&credit_card_cvv=672" \
              "$U/cart/checkout" | grep -qi "order is complete"
            echo "Smoke tests passed"
          '''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
      sh '''#!/bin/bash
        for s in ${SELECTED}; do docker rmi ${REGISTRY}/${REPO}/$s:${TAG} >/dev/null 2>&1 || true; done
        docker image prune -f >/dev/null 2>&1 || true
        rm -rf ${DOCKER_CONFIG}
      '''
    }
    failure {
      script {
        if (fileExists('.deploy_started')) {
          withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
            sh '''#!/bin/bash
              PREV=$(cat .prev_revision 2>/dev/null || true)
              if [ -n "$PREV" ]; then
                echo "AUTO-ROLLBACK to revision $PREV"
                helm rollback ${RELEASE} $PREV -n ${NAMESPACE} --wait --timeout 5m
              else
                echo "First install failed, removing the broken release"
                helm uninstall ${RELEASE} -n ${NAMESPACE} || true
              fi
            '''
          }
        }
        echo "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER} (${params.ENVIRONMENT}, ${env.TAG}) ${env.BUILD_URL}"
        if (params.NOTIFY_EMAIL?.trim()) {
          try { emailext to: params.NOTIFY_EMAIL, subject: "FAILED ${env.JOB_NAME} #${env.BUILD_NUMBER}", body: "Console: ${env.BUILD_URL}console" }
          catch (e) { echo "e-mail not sent: ${e.message}" }
        }
      }
    }
    success {
      script {
        echo "SUCCESS: ${params.ENVIRONMENT} now runs ${env.TAG}"
        if (params.NOTIFY_EMAIL?.trim()) {
          try { emailext to: params.NOTIFY_EMAIL, subject: "OK ${env.JOB_NAME} #${env.BUILD_NUMBER}", body: "${params.ENVIRONMENT} runs ${env.TAG}" }
          catch (e) { echo "e-mail not sent: ${e.message}" }
        }
      }
    }
  }
}
