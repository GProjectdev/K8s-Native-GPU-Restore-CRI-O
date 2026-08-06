// Command restore-orchestrator runs the WorkloadRestore/GPURestore controllers
// and the Pod mutating webhook. It is a single central Deployment (not the
// per-node DaemonSet). It only CREATES GPURestore objects and injects gpu-cr.io/*
// annotations into new Pods; the Custom CRI-O + Restore Agent do the actual work.
package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	rstv1alpha1 "github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O/orchestrator/api/v1alpha1"
	"github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O/orchestrator/controllers"
	gpuwebhook "github.com/GProjectdev/K8s-Native-GPU-Restore-CRI-O/orchestrator/webhook"
)

var scheme = runtime.NewScheme()

func init() {
	_ = clientgoscheme.AddToScheme(scheme)
	_ = rstv1alpha1.AddToScheme(scheme)
}

func main() {
	var (
		metricsAddr string
		probeAddr   string
		leaderElect bool
	)
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "metrics endpoint")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "health probe endpoint")
	flag.BoolVar(&leaderElect, "leader-elect", true, "enable leader election for HA")
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         leaderElect,
		LeaderElectionID:       "workload-restore.gpu-cr.io",
	})
	if err != nil {
		ctrl.Log.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := (&controllers.WorkloadRestoreReconciler{
		Client: mgr.GetClient(),
		API:    mgr.GetAPIReader(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "unable to set up WorkloadRestore controller")
		os.Exit(1)
	}
	if err := (&controllers.GPURestoreReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "unable to set up GPURestore controller")
		os.Exit(1)
	}

	// Mutating webhook: inject gpu-cr.io/* restore annotations into new Pods.
	mgr.GetWebhookServer().Register("/mutate-v1-pod", &admission.Webhook{
		Handler: &gpuwebhook.PodMutator{
			Client:  mgr.GetClient(),
			Decoder: admission.NewDecoder(mgr.GetScheme()),
		},
	})

	_ = mgr.AddHealthzCheck("healthz", healthz.Ping)
	_ = mgr.AddReadyzCheck("readyz", healthz.Ping)

	ctrl.Log.Info("restore orchestrator starting")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "manager exited")
		os.Exit(1)
	}
}
