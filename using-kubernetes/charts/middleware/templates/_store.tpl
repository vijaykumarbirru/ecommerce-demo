{{/*
"data-stores.store" — one StatefulSet + headless Service.
Args (dict): ctx (root), name, port, portName, cfg (values block), env (list),
             mountPath, probe (exec command list), storage (bool), extraPorts
*/}}
{{- define "data-stores.store" -}}
{{- $c := .ctx -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels: { app.kubernetes.io/name: {{ .name }}, app.kubernetes.io/part-of: ecommerce, app.kubernetes.io/component: data-store }
spec:
  clusterIP: None          # headless: DNS "{{ .name }}" points straight at the pod
  selector: { app.kubernetes.io/name: {{ .name }}, app.kubernetes.io/instance: {{ $c.Release.Name }} }
  ports:
    - { name: {{ .portName }}, port: {{ .port }} }
    {{- range .extraPorts }}
    - { name: {{ .name }}, port: {{ .port }} }
    {{- end }}
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ .name }}
  labels: { app.kubernetes.io/name: {{ .name }}, app.kubernetes.io/part-of: ecommerce, app.kubernetes.io/component: data-store }
spec:
  serviceName: {{ .name }}
  replicas: 1
  selector:
    matchLabels: { app.kubernetes.io/name: {{ .name }}, app.kubernetes.io/instance: {{ $c.Release.Name }} }
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ .name }}
        app.kubernetes.io/instance: {{ $c.Release.Name }}
        app.kubernetes.io/part-of: ecommerce
        app.kubernetes.io/component: data-store
    spec:
      containers:
        - name: {{ .name }}
          image: {{ .cfg.image }}
          ports:
            - { name: {{ .portName }}, containerPort: {{ .port }} }
            {{- range .extraPorts }}
            - { name: {{ .name }}, containerPort: {{ .port }} }
            {{- end }}
          {{- with .env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          readinessProbe:
            exec: { command: {{ toJson .probe }} }
            periodSeconds: 10
            timeoutSeconds: 8
          livenessProbe:
            exec: { command: {{ toJson .probe }} }
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
          resources:
            {{- toYaml .cfg.resources | nindent 12 }}
          {{- if .storage }}
          volumeMounts:
            - { name: data, mountPath: {{ .mountPath }} }
          {{- end }}
  {{- if .storage }}
  volumeClaimTemplates:      # one PersistentVolume per pod, kept across restarts
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        resources: { requests: { storage: {{ .cfg.storage }} } }
  {{- end }}
{{- end }}
