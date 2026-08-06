package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// WorkloadRestoreRef points back at the parent WorkloadRestore that created this
// per-Pod child (mirrors the slide's spec.workloadRestoreRef).
type WorkloadRestoreRef struct {
	// Name of the parent WorkloadRestore.
	// +kubebuilder:validation:Required
	Name string `json:"name"`
	// Namespace of the parent WorkloadRestore. Defaults to the child's namespace.
	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// CheckpointInfo locates ONE Pod's checkpoint artifacts and the source Pod UID
// that keys its GPU data blob (mirrors the slide's CheckpointInfo).
type CheckpointInfo struct {
	// PodUID is the ORIGINAL (checkpointed) Pod's UID. The GPU data blob lives at
	// <GCR_DATA_DIR>/<podUid>/data.blob and the restored interceptor re-opens it
	// under the same UID, so this must match the checkpoint. Recorded by the
	// checkpoint side, or recovered from the tar metadata (io.kubernetes.pod.uid).
	// +optional
	PodUID string `json:"podUid,omitempty"`

	// CheckpointURI is the checkpoint tar location, e.g.
	// "nfs://10.178.0.14/mnt/nfs/gcr/checkpoint-...tar". Consumed by Custom CRI-O
	// via the gpu-cr.io/checkpoint-uri annotation.
	// +kubebuilder:validation:Required
	CheckpointURI string `json:"checkpointUri"`

	// DataURI optionally overrides the GPU data blob location. Default: the
	// checkpoint URI with ".tar" replaced by ".blob".
	// +optional
	DataURI string `json:"dataUri,omitempty"`

	// Node is the node the checkpoint was taken on (informational / scheduling).
	// +optional
	Node string `json:"node,omitempty"`
}

// GPURestoreSpec is the desired restore of ONE Pod from a checkpoint.
type GPURestoreSpec struct {
	// WorkloadRestoreRef ties this child to its parent WorkloadRestore.
	// +optional
	WorkloadRestoreRef WorkloadRestoreRef `json:"workloadRestoreRef,omitempty"`

	// CheckpointInfo is the checkpoint file + source UID for this replica.
	// +kubebuilder:validation:Required
	CheckpointInfo CheckpointInfo `json:"checkpointInfo"`

	// TargetPodName is the source Pod name this checkpoint came from. The webhook
	// binds an unconsumed GPURestore of the matching workload to a newly created
	// Pod; for kind=Pod the names match, for Deployments they need not.
	// +optional
	TargetPodName string `json:"targetPodName,omitempty"`

	// BlobMode is propagated to gpu-cr.io/blob-mode ("copy" | "direct"). direct
	// makes CRI-O read the GPU blob from its NFS path instead of copying it.
	// +kubebuilder:validation:Enum=copy;direct
	// +optional
	BlobMode string `json:"blobMode,omitempty"`
}

// GPURestorePhase is the lifecycle phase of a GPURestore.
type GPURestorePhase string

const (
	// GRPhasePending: not yet consumed by a restored Pod.
	GRPhasePending GPURestorePhase = "Pending"
	// GRPhaseBound: the webhook injected this checkpoint into a Pod being created.
	GRPhaseBound GPURestorePhase = "Bound"
	// GRPhaseCompleted: the restored Pod is Running (GPU restore done).
	GRPhaseCompleted GPURestorePhase = "Completed"
	// GRPhaseFailed: the restored Pod failed.
	GRPhaseFailed GPURestorePhase = "Failed"
)

// GPURestoreStatus reports which Pod consumed this checkpoint and the phase.
type GPURestoreStatus struct {
	// Phase is the lifecycle phase.
	// +optional
	Phase GPURestorePhase `json:"phase,omitempty"`
	// RestoredPodName is the newly created Pod the webhook bound this to.
	// +optional
	RestoredPodName string `json:"restoredPodName,omitempty"`
	// Message carries human-readable detail.
	// +optional
	Message string `json:"message,omitempty"`
	// Conditions follow the standard Kubernetes condition convention.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=gpurst
// +kubebuilder:printcolumn:name="Parent",type=string,JSONPath=`.spec.workloadRestoreRef.name`
// +kubebuilder:printcolumn:name="SourcePod",type=string,JSONPath=`.spec.targetPodName`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="RestoredPod",type=string,JSONPath=`.status.restoredPodName`

// GPURestore is one Pod's restore: a checkpoint tar + source UID that the
// mutating webhook injects into a newly created Pod as gpu-cr.io/* annotations.
type GPURestore struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   GPURestoreSpec   `json:"spec,omitempty"`
	Status GPURestoreStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// GPURestoreList contains a list of GPURestore.
type GPURestoreList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []GPURestore `json:"items"`
}
