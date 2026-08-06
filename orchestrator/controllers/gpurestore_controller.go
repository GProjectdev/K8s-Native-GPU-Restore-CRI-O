package controllers

import (
	"context"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	rstv1alpha1 "github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O/orchestrator/api/v1alpha1"
)

// GPURestoreReconciler promotes a bound GPURestore to Completed once the Pod that
// the webhook bound it to is Running (i.e. the GPU restore finished). It performs
// no restore work — the Custom CRI-O + Restore Agent do that.
type GPURestoreReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=gpu-cr.io,resources=gpurestores,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=gpu-cr.io,resources=gpurestores/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch

func (r *GPURestoreReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var gr rstv1alpha1.GPURestore
	if err := r.Get(ctx, req.NamespacedName, &gr); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	// Terminal already.
	if gr.Status.Phase == rstv1alpha1.GRPhaseCompleted || gr.Status.Phase == rstv1alpha1.GRPhaseFailed {
		return ctrl.Result{}, nil
	}
	// Not bound to a Pod yet — wait for the webhook.
	if gr.Status.RestoredPodName == "" {
		return ctrl.Result{}, nil
	}
	var pod corev1.Pod
	err := r.Get(ctx, types.NamespacedName{Namespace: gr.Namespace, Name: gr.Status.RestoredPodName}, &pod)
	if apierrors.IsNotFound(err) {
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}
	if err != nil {
		return ctrl.Result{}, err
	}
	switch pod.Status.Phase {
	case corev1.PodRunning:
		gr.Status.Phase = rstv1alpha1.GRPhaseCompleted
		gr.Status.Message = "restored pod running"
	case corev1.PodFailed:
		gr.Status.Phase = rstv1alpha1.GRPhaseFailed
		gr.Status.Message = "restored pod failed"
	default:
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil
	}
	return ctrl.Result{}, r.Status().Update(ctx, &gr)
}

func (r *GPURestoreReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&rstv1alpha1.GPURestore{}).
		Complete(r)
}
