{{- define "garmin-health-data.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "garmin-health-data.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "garmin-health-data.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "garmin-health-data.labels" -}}
app.kubernetes.io/name: {{ include "garmin-health-data.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "garmin-health-data.selectorLabels" -}}
app.kubernetes.io/name: {{ include "garmin-health-data.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Runtime image that uvx runs in. */}}
{{- define "garmin-health-data.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{/* PyPI requirement: values.packageVersion overrides, else the chart appVersion. */}}
{{- define "garmin-health-data.requirement" -}}
{{- printf "garmin-health-data==%s" (.Values.packageVersion | default .Chart.AppVersion) -}}
{{- end -}}

{{/* Claim the pods mount: an existing one if given, else the chart's own. */}}
{{- define "garmin-health-data.claimName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "garmin-health-data.fullname" .) -}}
{{- end -}}
{{- end -}}
