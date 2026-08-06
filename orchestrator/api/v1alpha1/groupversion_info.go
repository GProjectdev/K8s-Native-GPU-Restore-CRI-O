// Package v1alpha1 defines the RESTORE control-plane API — WorkloadRestore (the
// high-level, workload-scoped restore trigger) and GPURestore (its per-Pod child,
// carrying the checkpoint location + source Pod UID for one replica).
//
// It shares the gpu-cr.io/v1alpha1 group with the checkpoint CRs (GPUCheckpoint,
// WorkloadCheckpoint) but lives in its own module/binary. The controller only
// CREATES GPURestore objects and a mutating webhook injects the gpu-cr.io/*
// annotations that the Custom CRI-O + Restore Agent already consume — so the
// existing data-plane is untouched.
//
// +kubebuilder:object:generate=true
// +groupName=gpu-cr.io
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion matches the existing CRs: apiVersion: gpu-cr.io/v1alpha1.
	GroupVersion = schema.GroupVersion{Group: "gpu-cr.io", Version: "v1alpha1"}

	// SchemeBuilder registers the restore kinds; checkpoint kinds live elsewhere.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the restore types to a scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)

func init() {
	SchemeBuilder.Register(&WorkloadRestore{}, &WorkloadRestoreList{}, &GPURestore{}, &GPURestoreList{})
}
