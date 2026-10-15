{{/*
"ecommerce-common.app" renders one shop service: a Deployment and (when the
service has a port) a ClusterIP Service named after the chart, e.g.
"cart-service" — the same hostnames the code uses in Docker Compose.

Values it reads (see any service sub-chart's values.yaml):
  image.repository / image.tag, replicas, port, health, startupSeconds,
  waitFor (host:port list -> init containers), env (map), secretEnv (list)
  — waitFor and env values are rendered with tpl, so they can reference
    {{ .Values.global.hosts.postgres }} and friends,
  otel (bool), resources, volumes, volumeMounts
*/}}
{{- define "ecommerce-common.app" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
  labels:
    {{- include "ecommerce-common.labels" . | nindent 4 }}
spec:
  # not `default 1`: that would turn an explicit replicas: 0 back into 1
  replicas: {{ if kindIs "invalid" .Values.replicas }}1{{ else }}{{ .Values.replicas }}{{ end }}
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      {{- include "ecommerce-common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "ecommerce-common.labels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- with .Values.waitFor }}
      # Kubernetes has no depends_on: wait for each dependency's port first.
      initContainers:
        {{- range . }}
        {{- $target := tpl . $ }}
        {{- $hp := splitList ":" $target }}
        - name: wait-for-{{ index (splitList "." (index $hp 0)) 0 }}
          image: {{ $.Values.global.busyboxImage }}
          command: ["sh", "-c", "until nc -z -w 2 {{ index $hp 0 }} {{ index $hp 1 }}; do echo waiting for {{ $target }}; sleep 2; done"]
          resources: { requests: { cpu: 5m, memory: 8Mi }, limits: { memory: 32Mi } }
        {{- end }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: {{ include "ecommerce-common.image" . }}
          imagePullPolicy: {{ .Values.global.imagePullPolicy }}
          {{- if .Values.port }}
          ports:
            - name: http
              containerPort: {{ .Values.port }}
          {{- end }}
          env:
            {{- if .Values.port }}
            - { name: PORT, value: {{ .Values.port | quote }} }
            {{- end }}
            {{- if .Values.otel | default false }}
            # Pod identity for OpenTelemetry resource attributes.
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: POD_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - { name: OTEL_SERVICE_NAME, value: {{ .Chart.Name | quote }} }
            - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: {{ .Values.global.otel.endpoint | quote }} }
            - { name: OTEL_EXPORTER_OTLP_PROTOCOL, value: http/protobuf }
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "{{ .Values.global.otel.resourceAttributes }},k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE),k8s.node.name=$(NODE_NAME)"
            {{- end }}
            {{- range .Values.secretEnv }}
            - name: {{ . }}
              valueFrom:
                secretKeyRef: { name: {{ $.Values.global.credentialsSecret }}, key: {{ . }} }
            {{- end }}
            {{- range $k, $v := .Values.env }}
            - { name: {{ $k }}, value: {{ tpl (toString $v) $ | quote }} }   {{- /* tpl: values may use {{ .Values.global.hosts.* }} */}}
            {{- end }}
          {{- if .Values.health }}
          startupProbe:          # generous: the JVM / .NET need time on first start
            httpGet: { path: {{ .Values.health }}, port: http }
            periodSeconds: 5
            failureThreshold: {{ div (.Values.startupSeconds | default 60) 5 }}
          readinessProbe:        # in the Service's endpoints only while healthy
            httpGet: { path: {{ .Values.health }}, port: http }
            periodSeconds: 10
          livenessProbe:         # restarted if it stops answering
            httpGet: { path: {{ .Values.health }}, port: http }
            periodSeconds: 20
            failureThreshold: 3
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          {{- with .Values.volumeMounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.volumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- if .Values.port }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
  labels:
    {{- include "ecommerce-common.labels" . | nindent 4 }}
spec:
  selector:
    {{- include "ecommerce-common.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.port }}
      targetPort: http
{{- end }}
{{- end }}
