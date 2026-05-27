// jwt-issuer — a tiny one-shot RSA JWT issuer for the agentic-mcp-rbac-kind lab.
//
// On startup:
//
//  1. Generate (or reuse) an RSA-2048 keypair. The private key is persisted as
//     a Secret `jwt-signing-key` in the issuer's own namespace so restarts
//     don't invalidate previously-minted tokens.
//
//  2. Sign three long-lived JWTs (10 years) for alice / bob / carol with
//     custom claims {sub, team, groups}. Each token is written as a Secret
//     in the `mcp-rbac` namespace where the rbac-inspector-ui Deployment
//     mounts the three of them at /etc/jwts/{alice,bob,carol}.
//
//  3. Publish the corresponding public JWKS as ConfigMap `jwt-jwks` in the
//     issuer's own namespace. The EnterpriseAgentgatewayPolicy
//     `jwtAuthentication.providers[].jwks.remote` backendRef points at the
//     /.well-known/jwks.json endpoint this service exposes (HTTP :8080).
//
//  4. Keep an HTTP server alive so the gateway can fetch the JWKS over
//     remote-JWKS (the use-case docs show jwks.remote pointing at a Service;
//     this service IS the JWKS provider for the lab).
//
// This is demo code — single replica, no rotation, never reissue.
package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	issuer       = "agentic-mcp-rbac-kind"
	signingKeyNS = "mcp-rbac"          // where the issuer + signing key live
	jwksCM       = "jwt-jwks"          // ConfigMap holding the public JWKS
	// tokenNS holds the per-user JWT Secrets. The rbac-inspector-ui pod
	// runs in the same namespace and mounts these three Secrets directly,
	// so we avoid the cross-namespace RBAC dance the old kagent-BYO-agent
	// version of the lab required.
	tokenNS      = "mcp-rbac"
	keyID        = "agentic-rbac-key-1"
)

// user → claims template
type user struct {
	sub    string
	team   string   // platform / dev / intern
	groups []string // ["admin"] grants the catch-all CEL rule
}

var users = []user{
	{sub: "alice", team: "platform", groups: []string{"admin"}},
	{sub: "bob",   team: "dev",      groups: []string{"dev"}},
	{sub: "carol", team: "intern",   groups: []string{"intern"}},
}

func main() {
	ctx := context.Background()
	cs, err := newClient()
	if err != nil {
		log.Fatalf("kube client: %v", err)
	}

	priv, err := loadOrCreateSigningKey(ctx, cs)
	if err != nil {
		log.Fatalf("signing key: %v", err)
	}

	// Mint + write three JWT Secrets.
	for _, u := range users {
		tok, err := mintJWT(priv, u)
		if err != nil {
			log.Fatalf("mint %s: %v", u.sub, err)
		}
		if err := writeSecret(ctx, cs, tokenNS, "jwt-"+u.sub, map[string][]byte{
			"token": []byte(tok),
			"sub":   []byte(u.sub),
			"team":  []byte(u.team),
		}); err != nil {
			log.Fatalf("write secret jwt-%s: %v", u.sub, err)
		}
		log.Printf("issued JWT for sub=%s team=%s groups=%v", u.sub, u.team, u.groups)
	}

	// Publish the JWKS as a ConfigMap (for any reader) AND serve it over HTTP
	// at /.well-known/jwks.json (the gateway fetches it that way).
	jwks, err := jwksJSON(&priv.PublicKey)
	if err != nil {
		log.Fatalf("jwks: %v", err)
	}
	if err := writeConfigMap(ctx, cs, signingKeyNS, jwksCM, map[string]string{
		"jwks.json": jwks,
	}); err != nil {
		log.Fatalf("write configmap %s: %v", jwksCM, err)
	}
	log.Printf("published JWKS to ConfigMap %s/%s and over HTTP", signingKeyNS, jwksCM)

	http.HandleFunc("/.well-known/jwks.json", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, jwks)
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "ok")
	})
	addr := ":8080"
	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("http: %v", err)
	}
}

func newClient() (*kubernetes.Clientset, error) {
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config: %w", err)
	}
	return kubernetes.NewForConfig(cfg)
}

// loadOrCreateSigningKey loads the persisted RSA private key from a Secret,
// or generates + persists a new one if absent. Persistence means restarts
// don't invalidate previously-issued tokens.
func loadOrCreateSigningKey(ctx context.Context, cs *kubernetes.Clientset) (*rsa.PrivateKey, error) {
	const name = "jwt-signing-key"
	sec, err := cs.CoreV1().Secrets(signingKeyNS).Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		blk, _ := pem.Decode(sec.Data["tls.key"])
		if blk == nil {
			return nil, errors.New("existing signing-key Secret has no PEM block")
		}
		k, err := x509.ParsePKCS1PrivateKey(blk.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse existing key: %w", err)
		}
		log.Printf("reusing existing signing key from %s/%s", signingKeyNS, name)
		return k, nil
	}
	if !apierrors.IsNotFound(err) {
		return nil, err
	}

	log.Printf("generating new RSA-2048 signing key")
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(k),
	})
	if err := writeSecret(ctx, cs, signingKeyNS, name, map[string][]byte{
		"tls.key": pemBytes,
	}); err != nil {
		return nil, fmt.Errorf("write signing-key secret: %w", err)
	}
	return k, nil
}

func mintJWT(priv *rsa.PrivateKey, u user) (string, error) {
	now := time.Now().UTC()
	claims := jwt.MapClaims{
		"iss":    issuer,
		"sub":    u.sub,
		"team":   u.team,
		"groups": u.groups,
		"iat":    now.Unix(),
		"exp":    now.AddDate(10, 0, 0).Unix(),
		"aud":    "ops-tools",
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = keyID
	return tok.SignedString(priv)
}

// jwksJSON builds a JSON-Web-Key-Set with one RSA key (the public side of
// our signing key). Format follows RFC 7517.
func jwksJSON(pub *rsa.PublicKey) (string, error) {
	type jwk struct {
		Kty string `json:"kty"`
		Use string `json:"use"`
		Alg string `json:"alg"`
		Kid string `json:"kid"`
		N   string `json:"n"`
		E   string `json:"e"`
	}
	type jwks struct {
		Keys []jwk `json:"keys"`
	}
	n := base64.RawURLEncoding.EncodeToString(pub.N.Bytes())
	eBytes := big.NewInt(int64(pub.E)).Bytes()
	e := base64.RawURLEncoding.EncodeToString(eBytes)
	out, err := json.MarshalIndent(jwks{Keys: []jwk{{
		Kty: "RSA", Use: "sig", Alg: "RS256", Kid: keyID, N: n, E: e,
	}}}, "", "  ")
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// writeSecret is an upsert — kubectl apply equivalent for Opaque secrets.
func writeSecret(ctx context.Context, cs *kubernetes.Clientset, ns, name string, data map[string][]byte) error {
	want := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		Type:       corev1.SecretTypeOpaque,
		Data:       data,
	}
	if _, err := cs.CoreV1().Secrets(ns).Create(ctx, want, metav1.CreateOptions{}); err == nil {
		return nil
	} else if !apierrors.IsAlreadyExists(err) {
		return err
	}
	_, err := cs.CoreV1().Secrets(ns).Update(ctx, want, metav1.UpdateOptions{})
	return err
}

func writeConfigMap(ctx context.Context, cs *kubernetes.Clientset, ns, name string, data map[string]string) error {
	want := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		Data:       data,
	}
	if _, err := cs.CoreV1().ConfigMaps(ns).Create(ctx, want, metav1.CreateOptions{}); err == nil {
		return nil
	} else if !apierrors.IsAlreadyExists(err) {
		return err
	}
	_, err := cs.CoreV1().ConfigMaps(ns).Update(ctx, want, metav1.UpdateOptions{})
	return err
}

