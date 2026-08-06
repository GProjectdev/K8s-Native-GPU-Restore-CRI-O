package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WorkloadTargetRef identifies the workload to restore (mirrors the checkpoint
// side's WorkloadTargetRef and the slide's spec.targetWorkloadRef).
type WorkloadTargetRef struct {
	// APIVersion (group/version) of the target, e.g. "apps/v1". Optional for the
	// common native kinds (Pod, Deployment, StatefulSet, ReplicaSet, Job).
	// +optional
	APIVersion string `json:"apiVersion,omitempty"`
	// Kind of the target workload, e.g. "Deployment".
	// +kubebuilder:default=Pod
	// +optional
	Kind string `json:"kind,omitempty"`
	// Namespace of the target workload.
	// +kubebuilder:validation:Required
	Namespace string `json:"namespace"`
	// Name of the target workload.
	// +kubebuilder:validation:Required
	Name string `json:"name"`
	// Container is the GPU container name propagated to each child.
	// +optional
	Container string `json:"container,omitempty"`
}

// CheckpointSourceRef points at the WorkloadCheckpoint whose status recorded WHERE
// each replica's checkpoint was stored. The controller reads it (dynamically, so
// no cross-repo Go dependency) to fan out GPURestore children.
type CheckpointSourceRef struct {
	// Name of the source WorkloadCheckpoint.
	// +kubebuilder:validation:Required
	Name string `json:"name"`
	// Namespace of the source WorkloadCheckpoint. Defaults to the WorkloadRestore's.
	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// WorkloadRestoreSpec is the desired restore of a whole workload.
type WorkloadRestoreSpec struct {
	// TargetWorkloadRef is the workload whose new Pods should be restored from a
	// checkpoint (the slide's spec.targetWorkloadRef).
	// +kubebuilder:validation:Required
	TargetWorkloadRef WorkloadTargetRef `json:"targetWorkloadRef"`

	// CheckpointRef names the source WorkloadCheckpoint that recorded the per-Pod
	// checkpoint artifacts. If empty, GPURestore children must be provided directly.
	// +optional
	CheckpointRef *CheckpointSourceRef `json:"checkpointRef,omitempty"`

	// Server is the NFS server IP used to turn stored checkpoint PATHS into
	// nfs://<server><path> URIs. Optional if the checkpoint status already stores
	// full URIs.
	// +optional
	Server string `json:"server,omitempty"`

	// BlobMode is propagated to every child / the gpu-cr.io/blob-mode annotation
	// ("copy" | "direct").
	// +kubebuilder:validation:Enum=copy;direct
	// +optional
	BlobMode string `json:"blobMode,omitempty"`
}

// WorkloadRestorePhase is the aggregate lifecycle phase.
type WorkloadRestorePhase string

const (
	WRPhasePending    WorkloadRestorePhase = "Pending"
	WRPhaseResolving  WorkloadRestorePhase = "Resolving"
	WRPhaseInProgress WorkloadRestorePhase = "InProgress"
	WRPhaseCompleted  WorkloadRestorePhase = "Completed"
	WRPhaseFailed     WorkloadRestorePhase = "Failed"
)

// RestoreTargetStatus is the per-child rollup shown on the parent.
type RestoreTargetStatus struct {
	// SourcePodName is the original checkpointed Pod.
	SourcePodName string `json:"sourcePodName"`
	// ChildName is the owned GPURestore object.
	// +optional
	ChildName string `json:"childName,omitempty"`
	// CheckpointURI is the checkpoint tar for this replica.
	// +optional
	CheckpointURI string `json:"checkpointUri,omitempty"`
	// Phase mirrors the child GPURestore.status.phase.
	// +optional
	Phase string `json:"phase,omitempty"`
	// RestoredPodName is the new Pod that consumed this checkpoint.
	// +optional
	RestoredPodName string `json:"restoredPodName,omitempty"`
}

// WorkloadRestoreStatus is the observed, aggregated restore state.
type WorkloadRestoreStatus struct {
	// Phase is the aggregate lifecycle phase.
	// +optional
	Phase WorkloadRestorePhase `json:"phase,omitempty"`
	// Total is the number of per-Pod checkpoints (children expected).
	// +optional
	Total int32 `json:"total"`
	// Active is the number of children not yet completed/failed.
	// +optional
	Active int32 `json:"active"`
	// Completed is the number of replicas restored and Running.
	// +optional
	Completed int32 `json:"completed"`
	// Failed is the number of children that failed.
	// +optional
	Failed int32 `json:"failed"`
	// Targets is the per-child rollup.
	// +optional
	Targets []RestoreTargetStatus `json:"targets,omitempty"`
	// Message carries human-readable aggregate detail.
	// +optional
	Message string `json:"message,omitempty"`
	// Conditions follow the standard Kubernetes condition convention.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=wrst
// +kubebuilder:printcolumn:name="Kind",type=string,JSONPath=`.spec.targetWorkloadRef.kind`
// +kubebuilder:printcolumn:name="Workload",type=string,JSONPath=`.spec.targetWorkloadRef.name`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Total",type=integer,JSONPath=`.status.total`
// +kubebuilder:printcolumn:name="Done",type=integer,JSONPath=`.status.completed`

// WorkloadRestore fans a workload-wide restore out to per-Pod GPURestore children
// (one per checkpointed replica) and aggregates their status.
type WorkloadRestore struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WorkloadRestoreSpec   `json:"spec,omitempty"`
	Status WorkloadRestoreStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WorkloadRestoreList contains a list of WorkloadRestore.
type WorkloadRestoreList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WorkloadRestore `json:"items"`
}
