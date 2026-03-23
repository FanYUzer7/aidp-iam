{{/*
Expand the name of the chart.
*/}}
{{- define "rubik-frontend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rubik-frontend.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "rubik-frontend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rubik-frontend.labels" -}}
helm.sh/chart: {{ include "rubik-frontend.chart" . }}
{{ include "rubik-frontend.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rubik-frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rubik-frontend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Target namespace
*/}}
{{- define "rubik-frontend.namespace" -}}
{{- if .Values.namespace }}
{{- .Values.namespace }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{/*
Rubik backend service URL
自动组合后端服务地址，基于 backend.serviceName 和 backend.servicePort
同 namespace 下直接使用服务名，跨 namespace 需使用 FQDN
*/}}
{{- define "rubik-frontend.backendUrl" -}}
{{- $host := .Values.backend.serviceName -}}
{{- $port := .Values.backend.servicePort -}}
{{- $path := .Values.backend.apiPath -}}
{{- printf "http://%s:%d%s" $host $port $path | quote }}
{{- end }}
