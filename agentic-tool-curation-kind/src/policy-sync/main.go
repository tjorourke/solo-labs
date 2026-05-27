// policy-sync — watches the curation-manifest ConfigMap and (re)applies the
// EnterpriseAgentgatewayPolicy that pins the gateway's tool allow-list.
//
// This is the "registry is the source of truth" proof point. When a curator
// edits the manifest (in real life: publishes a new MCPServer artifact in
// agentregistry; in this lab: edits the ConfigMap), this controller
// regenerates the gateway policy's CEL matchExpressions list so the gateway
// immediately starts denying anything outside the approved set.
//
// The controller writes ONE resource: the EnterpriseAgentgatewayPolicy named
// "mcp-tool-allowlist" in the tool-curation namespace. It does NOT manage the
// JWT policy or any other AGW resource — those are owned by the bring-up
// scripts.
//
// Implementation notes:
//
//   - We use client-go's dynamic client for the EnterpriseAgentgatewayPolicy
//     because the project's CRD generated types aren't available in OSS.
//     Hand-built unstructured.Unstructured is fine here — the schema is tiny.
//   - We watch the ConfigMap with a Reflector + ResourceEventHandler. Edge-
//     triggered. On error, log and continue — the reflector retries.
//   - Single-replica only; no leader election. Demo cluster.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"sigs.k8s.io/yaml"
)

const (
	envNamespace        = "POLICY_SYNC_NAMESPACE"
	envManifestCM       = "MANIFEST_CONFIGMAP"
	envPolicyName       = "POLICY_NAME"
	envBackendName      = "BACKEND_NAME"
	envBackendNamespace = "BACKEND_NAMESPACE"
	envResyncSeconds    = "RESYNC_SECONDS"
)

func getenv(k, def string) string {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	return v
}

// CurationManifest mirrors the YAML in the curation-manifest ConfigMap.
type CurationManifest struct {
	ApprovedTools []ApprovedTool `json:"approvedTools"`
	// ForbiddenChains is consumed by the ext-auth, not by this controller —
	// included here only for documentation. The ext-auth reads the same
	// ConfigMap independently.
	ForbiddenChains [][]string `json:"forbiddenChains,omitempty"`
}

type ApprovedTool struct {
	Name             string                 `json:"name"`
	RiskTier         string                 `json:"riskTier,omitempty"`
	RequiredIntent   string                 `json:"requiredIntent,omitempty"`
	CleanDescription string                 `json:"cleanDescription,omitempty"`
	ArgsSchema       map[string]interface{} `json:"argsSchema,omitempty"`
}

var policyGVR = schema.GroupVersionResource{
	Group:    "enterpriseagentgateway.solo.io",
	Version:  "v1alpha1",
	Resource: "enterpriseagentgatewaypolicies",
}

func main() {
	ns := getenv(envNamespace, "tool-curation")
	cmName := getenv(envManifestCM, "curation-manifest")
	policyName := getenv(envPolicyName, "mcp-tool-allowlist")
	backendName := getenv(envBackendName, "rogue-mcp-backend")
	backendNamespace := getenv(envBackendNamespace, "tool-curation")
	resync, _ := time.ParseDuration(getenv(envResyncSeconds, "60") + "s")

	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("in-cluster config: %v", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("kube client: %v", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("dynamic client: %v", err)
	}

	// Tiny status server so the kubelet readiness probe has a target.
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})
	go func() {
		log.Printf("status server on :8080")
		_ = http.ListenAndServe(":8080", mux)
	}()

	ctx := context.Background()

	// Wait until the ConfigMap exists at least once — eliminates a startup
	// race where we run before the bring-up scripts have applied it.
	log.Printf("waiting for ConfigMap %s/%s to exist", ns, cmName)
	if err := wait.PollUntilContextCancel(ctx, 2*time.Second, true, func(ctx context.Context) (bool, error) {
		_, err := cs.CoreV1().ConfigMaps(ns).Get(ctx, cmName, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return err == nil, err
	}); err != nil {
		log.Fatalf("waiting for manifest: %v", err)
	}
	log.Printf("ConfigMap %s/%s observed — starting informer", ns, cmName)

	// SingleObject informer scoped to one ns + one name. Lighter than a
	// namespace-wide ConfigMap informer.
	factory := informers.NewSharedInformerFactoryWithOptions(cs, resync,
		informers.WithNamespace(ns),
		informers.WithTweakListOptions(func(opts *metav1.ListOptions) {
			opts.FieldSelector = fmt.Sprintf("metadata.name=%s", cmName)
		}),
	)
	cmInformer := factory.Core().V1().ConfigMaps().Informer()

	handle := func(obj interface{}) {
		cm, ok := obj.(*corev1.ConfigMap)
		if !ok || cm.Name != cmName {
			return
		}
		raw := cm.Data["manifest.yaml"]
		if raw == "" {
			log.Printf("WARN: ConfigMap %s/%s has empty manifest.yaml — skipping", ns, cmName)
			return
		}
		var manifest CurationManifest
		if err := yaml.Unmarshal([]byte(raw), &manifest); err != nil {
			log.Printf("ERROR: parse manifest: %v", err)
			return
		}
		if len(manifest.ApprovedTools) == 0 {
			log.Printf("WARN: manifest has 0 approved tools — gateway will deny everything")
		}

		if err := applyPolicy(ctx, dyn, policyName, ns, backendName, backendNamespace, manifest); err != nil {
			log.Printf("ERROR: applyPolicy: %v", err)
			return
		}
		names := make([]string, 0, len(manifest.ApprovedTools))
		for _, t := range manifest.ApprovedTools {
			names = append(names, t.Name)
		}
		log.Printf("applied %s/%s — allowed tools: %v", ns, policyName, names)
	}

	_, _ = cmInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    handle,
		UpdateFunc: func(_, n interface{}) { handle(n) },
		// We don't delete the policy when the manifest goes away — a stale
		// CRD remaining is safer than briefly opening up the gateway.
	})

	stop := make(chan struct{})
	defer close(stop)
	factory.Start(stop)
	factory.WaitForCacheSync(stop)
	log.Printf("informer running")
	<-stop
}

// applyPolicy renders + server-side-applies the EnterpriseAgentgatewayPolicy.
//
// We use a stable CEL matchExpression of the form:
//
//	mcp.tool.name in ["a","b","c"]
//
// which makes the gateway deny tool calls (and filter tools/list) for any
// name not in the list. Empty list ⇒ everything denied.
func applyPolicy(
	ctx context.Context,
	dyn dynamic.Interface,
	policyName, policyNamespace string,
	backendName, backendNamespace string,
	manifest CurationManifest,
) error {
	cel := buildCELAllowExpression(manifest.ApprovedTools)

	policy := map[string]interface{}{
		"apiVersion": "enterpriseagentgateway.solo.io/v1alpha1",
		"kind":       "EnterpriseAgentgatewayPolicy",
		"metadata": map[string]interface{}{
			"name":      policyName,
			"namespace": policyNamespace,
			"labels": map[string]interface{}{
				"app.kubernetes.io/managed-by": "policy-sync",
				"curation.solo.io/source":      "curation-manifest",
			},
		},
		"spec": map[string]interface{}{
			"targetRefs": []interface{}{
				map[string]interface{}{
					"group": "agentgateway.dev",
					"kind":  "AgentgatewayBackend",
					"name":  backendName,
				},
			},
			"backend": map[string]interface{}{
				"mcp": map[string]interface{}{
					"authorization": map[string]interface{}{
						"action": "Allow",
						"policy": map[string]interface{}{
							"matchExpressions": []interface{}{cel},
						},
					},
				},
			},
		},
	}
	_ = backendNamespace // backend targetRef is namespace-local in the AGW
	// authz policy schema; the backend is colocated with the policy.

	buf, err := json.Marshal(policy)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	obj := &unstructured.Unstructured{}
	if err := obj.UnmarshalJSON(buf); err != nil {
		return fmt.Errorf("unmarshal: %w", err)
	}

	_, err = dyn.Resource(policyGVR).Namespace(policyNamespace).Patch(
		ctx, policyName, types.ApplyPatchType, buf,
		metav1.PatchOptions{FieldManager: "policy-sync", Force: ptrTrue()},
	)
	return err
}

func buildCELAllowExpression(tools []ApprovedTool) string {
	if len(tools) == 0 {
		// Empty allow-list: evaluates to false for any tool name.
		return `mcp.tool.name == "__NEVER_MATCHED__"`
	}
	out := "mcp.tool.name in ["
	for i, t := range tools {
		if i > 0 {
			out += ","
		}
		out += fmt.Sprintf("%q", t.Name)
	}
	out += "]"
	return out
}

func ptrTrue() *bool { b := true; return &b }
