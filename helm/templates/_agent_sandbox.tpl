{{/* Existing standalone CRDs must not cause a Helm ownership conflict.
     Keep rendering CRDs owned by this release so upgrades do not delete them.
     Offline rendering (including OLM bundle generation) includes all CRDs. */}}
{{- define "konveyor.installSandboxCRD" -}}
{{- $crd := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" .name -}}
{{- $annotations := dig "metadata" "annotations" (dict) $crd -}}
{{- if or (not $crd) (and
      (eq (get $annotations "meta.helm.sh/release-name") .root.Release.Name)
      (eq (get $annotations "meta.helm.sh/release-namespace") .root.Release.Namespace)) -}}
true
{{- end -}}
{{- end -}}
