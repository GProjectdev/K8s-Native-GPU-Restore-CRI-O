// Package controllers holds the RESTORE orchestrator controllers. The
// WorkloadRestore controller resolves a workload's SOURCE checkpoints (recorded
// by a WorkloadCheckpoint) and fans them out to per-Pod GPURestore children. It
// performs no restore work itself — a mutating webhook injects the gpu-cr.io/*
// annotations into newly created Pods, which the Custom CRI-O + Restore Agent
// (the existing data plane) then act on.
package controllers

import (
	"context"
	"fmt"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	rstv1alpha1 "github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O/orchestrator/api/v1alpha1"
)

// ownedByLabel ties GPURestore children back to their parent WorkloadRestore.
const ownedByLabel = "gpu-cr.io/workload-restore"

// WorkloadRestoreReconciler reconciles WorkloadRestore objects.
type WorkloadRestoreReconciler struct {
	client.Client
	// API is an uncached reader used to GET arbitrary resources (the source
	// WorkloadCheckpoint CR is read dynamically to avoid a cross-repo import).
	API    client.Reader
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=gpu-cr.io,resources=workloadrestores,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=gpu-cr.io,resources=workloadrestores/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=gpu-cr.io,resources=gpurestores,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=gpu-cr.io,resources=gpurestores/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=gpu-cr.io,resources=workloadcheckpoints,verbs=get;list;watch

// Reconcile reads the source WorkloadCheckpoint's per-Pod records and ensures one
// GPURestore child per checkpointed replica, then aggregates children.
func (r *WorkloadRestoreReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	lg := log.FromContext(ctx)

	var wr rstv1alpha1.WorkloadRestore
	if err := r.Get(ctx, req.NamespacedName, &wr); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if wr.Spec.CheckpointRef == nil {
		return r.finish(ctx, &wr, rstv1alpha1.WRPhaseFailed,
			"spec.checkpointRef is required (names the source WorkloadCheckpoint to restore from)")
	}

	// (1) Read the source checkpoints from the WorkloadCheckpoint status (dynamic
	// read — no cross-repo Go dependency).
	targets, err := r.readCheckpointTargets(ctx, &wr)
	if err != nil {
		return r.finish(ctx, &wr, rstv1alpha1.WRPhaseFailed, "read WorkloadCheckpoint: "+err.Error())
	}
	if len(targets) == 0 {
		return r.finish(ctx, &wr, rstv1alpha1.WRPhaseFailed, "source WorkloadCheckpoint has no completed targets to restore")
	}

	// (2) Ensure one GPURestore child per source checkpoint.
	created := 0
	for i := range targets {
		t := targets[i]
		name := childName(wr.Name, t.SourcePodName)
		var child rstv1alpha1.GPURestore
		errGet := r.Get(ctx, types.NamespacedName{Namespace: wr.Namespace, Name: name}, &child)
		if errGet == nil {
			continue
		}
		if !apierrors.IsNotFound(errGet) {
			return ctrl.Result{}, errGet
		}
		child = r.buildChild(&wr, t, name)
		if err := ctrl.SetControllerReference(&wr, &child, r.Scheme); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.Create(ctx, &child); err != nil && !apierrors.IsAlreadyExists(err) {
			return ctrl.Result{}, err
		}
		created++
		lg.Info("created GPURestore child", "child", name, "sourcePod", t.SourcePodName, "uri", t.CheckpointURI)
	}

	// (3) Aggregate children into the parent status.
	return ctrl.Result{}, r.aggregate(ctx, &wr, targets)
}

// srcTarget is one resolved source checkpoint.
type srcTarget struct {
	SourcePodName string
	Node          string
	CheckpointURI string
	PodUID        string
}

// readCheckpointTargets loads the referenced WorkloadCheckpoint dynamically and
// extracts its status.targets[] (podName, node, path, podUID). Bare paths are
// turned into nfs://<server><path> URIs when spec.server is set.
func (r *WorkloadRestoreReconciler) readCheckpointTargets(ctx context.Context, wr *rstv1alpha1.WorkloadRestore) ([]srcTarget, error) {
	ns := wr.Spec.CheckpointRef.Namespace
	if ns == "" {
		ns = wr.Namespace
	}
	wc := &unstructured.Unstructured{}
	wc.SetGroupVersionKind(schema.GroupVersionKind{Group: "gpu-cr.io", Version: "v1alpha1", Kind: "WorkloadCheckpoint"})
	if err := r.reader().Get(ctx, types.NamespacedName{Namespace: ns, Name: wr.Spec.CheckpointRef.Name}, wc); err != nil {
		return nil, err
	}
	items, found, err := unstructured.NestedSlice(wc.Object, "status", "targets")
	if err != nil || !found {
		return nil, fmt.Errorf("WorkloadCheckpoint %s/%s has no status.targets", ns, wr.Spec.CheckpointRef.Name)
	}
	out := make([]srcTarget, 0, len(items))
	for _, it := range items {
		m, ok := it.(map[string]interface{})
		if !ok {
			continue
		}
		phase, _, _ := unstructured.NestedString(m, "phase")
		path, _, _ := unstructured.NestedString(m, "path")
		if path == "" || (phase != "" && phase != "Completed") {
			continue // only restore replicas that finished with a stored artifact
		}
		pod, _, _ := unstructured.NestedString(m, "podName")
		node, _, _ := unstructured.NestedString(m, "node")
		// podUID may be recorded by the checkpoint side (best-effort); if empty the
		// data blob path cannot be keyed automatically — see README (integration note).
		uid, _, _ := unstructured.NestedString(m, "podUID")
		if uid == "" {
			uid, _, _ = unstructured.NestedString(m, "podUid")
		}
		out = append(out, srcTarget{
			SourcePodName: pod,
			Node:          node,
			CheckpointURI: r.toURI(wr, path),
			PodUID:        uid,
		})
	}
	return out, nil
}

// toURI turns a stored checkpoint path into a URI CRI-O can stage. If the value
// already has a scheme it is used as-is; otherwise nfs://<server><path> when
// spec.server is set, else the bare path (hostpath, same-node).
func (r *WorkloadRestoreReconciler) toURI(wr *rstv1alpha1.WorkloadRestore, path string) string {
	if strings.Contains(path, "://") {
		return path
	}
	if wr.Spec.Server != "" {
		return fmt.Sprintf("nfs://%s%s", wr.Spec.Server, path)
	}
	return path
}

// buildChild constructs a per-Pod GPURestore for one source checkpoint.
func (r *WorkloadRestoreReconciler) buildChild(wr *rstv1alpha1.WorkloadRestore, t srcTarget, name string) rstv1alpha1.GPURestore {
	return rstv1alpha1.GPURestore{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: wr.Namespace,
			Labels:    map[string]string{ownedByLabel: wr.Name},
		},
		Spec: rstv1alpha1.GPURestoreSpec{
			WorkloadRestoreRef: rstv1alpha1.WorkloadRestoreRef{Name: wr.Name, Namespace: wr.Namespace},
			CheckpointInfo: rstv1alpha1.CheckpointInfo{
				PodUID:        t.PodUID,
				CheckpointURI: t.CheckpointURI,
				Node:          t.Node,
			},
			TargetPodName: t.SourcePodName,
			BlobMode:      wr.Spec.BlobMode,
		},
	}
}

// aggregate rolls child GPURestore statuses up into the parent WorkloadRestore.
func (r *WorkloadRestoreReconciler) aggregate(ctx context.Context, wr *rstv1alpha1.WorkloadRestore, targets []srcTarget) error {
	var children rstv1alpha1.GPURestoreList
	if err := r.List(ctx, &children, client.InNamespace(wr.Namespace),
		client.MatchingLabels{ownedByLabel: wr.Name}); err != nil {
		return err
	}
	byName := map[string]*rstv1alpha1.GPURestore{}
	for i := range children.Items {
		byName[children.Items[i].Name] = &children.Items[i]
	}

	var total, active, done, failed int32
	rollup := make([]rstv1alpha1.RestoreTargetStatus, 0, len(targets))
	for i := range targets {
		t := targets[i]
		total++
		cn := childName(wr.Name, t.SourcePodName)
		ts := rstv1alpha1.RestoreTargetStatus{SourcePodName: t.SourcePodName, ChildName: cn, CheckpointURI: t.CheckpointURI}
		if c, ok := byName[cn]; ok {
			ts.Phase = string(c.Status.Phase)
			ts.RestoredPodName = c.Status.RestoredPodName
			switch c.Status.Phase {
			case rstv1alpha1.GRPhaseCompleted:
				done++
			case rstv1alpha1.GRPhaseFailed:
				failed++
			default:
				active++
			}
		} else {
			ts.Phase = string(rstv1alpha1.GRPhasePending)
			active++
		}
		rollup = append(rollup, ts)
	}

	wr.Status.Total = total
	wr.Status.Active = active
	wr.Status.Completed = done
	wr.Status.Failed = failed
	wr.Status.Targets = rollup
	switch {
	case done == total:
		wr.Status.Phase = rstv1alpha1.WRPhaseCompleted
		wr.Status.Message = "all replicas restored"
	case done+failed == total && done == 0:
		wr.Status.Phase = rstv1alpha1.WRPhaseFailed
		wr.Status.Message = "all replicas failed"
	default:
		wr.Status.Phase = rstv1alpha1.WRPhaseInProgress
	}
	return r.Status().Update(ctx, wr)
}

func (r *WorkloadRestoreReconciler) finish(ctx context.Context, wr *rstv1alpha1.WorkloadRestore, phase rstv1alpha1.WorkloadRestorePhase, msg string) (ctrl.Result, error) {
	wr.Status.Phase = phase
	wr.Status.Message = msg
	return ctrl.Result{}, r.Status().Update(ctx, wr)
}

func (r *WorkloadRestoreReconciler) reader() client.Reader {
	if r.API != nil {
		return r.API
	}
	return r.Client
}

// childName is a deterministic, DNS-1123-safe name for a source Pod's child.
func childName(parent, pod string) string {
	base := parent + "-" + pod
	if len(base) <= 253 {
		return base
	}
	return base[:253]
}

// SetupWithManager wires the controller: it owns GPURestore children.
func (r *WorkloadRestoreReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&rstv1alpha1.WorkloadRestore{}).
		Owns(&rstv1alpha1.GPURestore{}).
		Complete(r)
}
