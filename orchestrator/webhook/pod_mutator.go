// Package webhook holds the mutating admission webhook that injects the
// gpu-cr.io/* restore annotations into newly created Pods, so the Custom CRI-O
// stages the checkpoint and restores the container. It matches a Pod to its
// workload (owner-walk), finds an unconsumed GPURestore for that workload, and
// binds it to this Pod — realizing the slide's "Mutation Webhook" that replaces a
// newly created Pod with its checkpoint files based on the GPURestore CR.
package webhook

import (
	"context"
	"encoding/json"
	"net/http"

	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	rstv1alpha1 "github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O/orchestrator/api/v1alpha1"
)

// PodMutator injects restore annotations into Pods created for a workload that
// has an active WorkloadRestore.
type PodMutator struct {
	Client  client.Client
	Decoder admission.Decoder
}

// +kubebuilder:webhook:path=/mutate-v1-pod,mutating=true,failurePolicy=ignore,sideEffects=NoneOnDryRun,groups="",resources=pods,verbs=create,versions=v1,name=pod-restore.gpu-cr.io,admissionReviewVersions=v1

func (m *PodMutator) Handle(ctx context.Context, req admission.Request) admission.Response {
	lg := log.FromContext(ctx)
	pod := &corev1.Pod{}
	if err := m.Decoder.Decode(req, pod); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}
	ns := req.Namespace
	if ns == "" {
		ns = pod.Namespace
	}

	// Already carries the restore annotation (e.g. hand-authored) — leave as-is.
	if pod.Annotations["gpu-cr.io/restore"] == "true" {
		return admission.Allowed("already a restore pod")
	}

	// Identify the workload this Pod belongs to (kind+name), walking owner refs.
	kind, name := m.workloadOf(ctx, ns, pod)

	// Find a WorkloadRestore whose targetWorkloadRef matches.
	var wrl rstv1alpha1.WorkloadRestoreList
	if err := m.Client.List(ctx, &wrl, client.InNamespace(ns)); err != nil {
		return admission.Allowed("no workloadrestore list")
	}
	var match *rstv1alpha1.WorkloadRestore
	for i := range wrl.Items {
		t := wrl.Items[i].Spec.TargetWorkloadRef
		tk := t.Kind
		if tk == "" {
			tk = "Pod"
		}
		if t.Namespace == ns && t.Name == name && tk == kind {
			match = &wrl.Items[i]
			break
		}
	}
	if match == nil {
		return admission.Allowed("no matching workloadrestore")
	}

	// Pick an unconsumed GPURestore child of that WorkloadRestore.
	var grl rstv1alpha1.GPURestoreList
	if err := m.Client.List(ctx, &grl, client.InNamespace(ns),
		client.MatchingLabels{"gpu-cr.io/workload-restore": match.Name}); err != nil {
		return admission.Allowed("no gpurestore list")
	}
	var child *rstv1alpha1.GPURestore
	for i := range grl.Items {
		if grl.Items[i].Status.RestoredPodName == "" && grl.Items[i].Status.Phase != rstv1alpha1.GRPhaseCompleted {
			child = &grl.Items[i]
			break
		}
	}
	if child == nil {
		return admission.Allowed("all checkpoints already bound")
	}

	// Inject the gpu-cr.io/* annotations the Custom CRI-O consumes.
	if pod.Annotations == nil {
		pod.Annotations = map[string]string{}
	}
	ci := child.Spec.CheckpointInfo
	pod.Annotations["gpu-cr.io/restore"] = "true"
	pod.Annotations["gpu-cr.io/checkpoint-uri"] = ci.CheckpointURI
	if ci.PodUID != "" {
		pod.Annotations["gpu-cr.io/source-pod-uid"] = ci.PodUID
	}
	if ci.DataURI != "" {
		pod.Annotations["gpu-cr.io/data-uri"] = ci.DataURI
	}
	if child.Spec.BlobMode != "" {
		pod.Annotations["gpu-cr.io/blob-mode"] = child.Spec.BlobMode
	}

	// Bind the child to this Pod so no other Pod consumes the same checkpoint.
	boundName := pod.Name
	if boundName == "" {
		boundName = pod.GenerateName + "(pending)"
	}
	child.Status.Phase = rstv1alpha1.GRPhaseBound
	child.Status.RestoredPodName = boundName
	if err := m.Client.Status().Update(ctx, child); err != nil {
		// If the bind update races, don't block Pod creation; another admission
		// will pick a different child.
		lg.Info("gpurestore bind update failed; allowing pod without injection", "err", err.Error())
		return admission.Allowed("bind race; not injected")
	}

	marshaled, err := json.Marshal(pod)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}
	lg.Info("injected restore annotations", "pod", boundName, "gpurestore", child.Name, "uri", ci.CheckpointURI)
	return admission.PatchResponseFromRaw(req.Object.Raw, marshaled)
}

// workloadOf returns the (kind,name) of the top-level workload owning the Pod by
// walking one or two ownerReference levels (Pod -> ReplicaSet -> Deployment;
// Pod -> StatefulSet/Job). Falls back to (Pod, pod.Name) when there is no owner.
func (m *PodMutator) workloadOf(ctx context.Context, ns string, pod *corev1.Pod) (string, string) {
	owner := controllerRefName(pod.OwnerReferences)
	if owner == nil {
		if pod.Name != "" {
			return "Pod", pod.Name
		}
		return "Pod", pod.GenerateName
	}
	switch owner.Kind {
	case "ReplicaSet":
		var rs appsv1.ReplicaSet
		if err := m.Client.Get(ctx, types.NamespacedName{Namespace: ns, Name: owner.Name}, &rs); err == nil {
			if d := controllerRefNameMeta(rs.OwnerReferences); d != nil && d.Kind == "Deployment" {
				return "Deployment", d.Name
			}
		}
		return "ReplicaSet", owner.Name
	default:
		// StatefulSet, Job, DaemonSet, or a CRD-owned Pod: use the direct owner.
		return owner.Kind, owner.Name
	}
}

type ownerRef struct{ Kind, Name string }

func controllerRefName(owners []metav1.OwnerReference) *ownerRef {
	for i := range owners {
		if owners[i].Controller != nil && *owners[i].Controller {
			return &ownerRef{Kind: owners[i].Kind, Name: owners[i].Name}
		}
	}
	if len(owners) > 0 {
		return &ownerRef{Kind: owners[0].Kind, Name: owners[0].Name}
	}
	return nil
}

func controllerRefNameMeta(owners []metav1.OwnerReference) *ownerRef { return controllerRefName(owners) }
