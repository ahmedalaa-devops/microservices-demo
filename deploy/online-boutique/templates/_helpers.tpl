{{- define "ob.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: online-boutique
environment: {{ .Values.global.environment | quote }}
{{- end -}}
