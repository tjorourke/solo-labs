// jwt-issuer — a tiny one-shot RSA JWT issuer for agentic-tool-curation-kind.
//
// On startup:
//
//  1. Generate (or reuse) an RSA-2048 keypair, persisted as Secret
//     `jwt-signing-key` so restarts don't invalidate previously-minted tokens.
//
//  2. Sign one JWT per "intent" (general, ops-secret-rotation), 10y expiry,
//     with custom claim `intent`. Each token is written as a Secret in the
//     `tool-curation` namespace where curation-inspector-ui mounts them at
//     /etc/jwts/{general,secret-rot}.
//
//  3. Publish the corresponding public JWKS as ConfigMap `jwt-jwks`. The
//     EnterpriseAgentgatewayPolicy `jwtAuthentication.providers[].jwks.remote`
//     backendRef points at the /.well-known/jwks.json endpoint here.
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
	issuer       = "agentic-tool-curation-kind"
	signingKeyNS = "tool-curation"
	jwksCM       = "jwt-jwks"
	tokenNS      = "tool-curation"
	keyID        = "agentic-curation-key-1"
)

// identity → claims template. Two identities, same subject, differing only
// by intent. The inspector UI exposes a dropdown to flip between them.
type identity struct {
	name   string // file name under /etc/jwts in the inspector pod
	sub    string
	intent string // matches `requiredIntent` on high-risk tools in the manifest
}

var identities = []identity{
	{name: "general",    sub: "agent", intent: "general"},
	{name: "secret-rot", sub: "agent", intent: "ops-secret-rotation"},
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

	// Mint + write one JWT Secret per intent.
	for _, id := range identities {
		tok, err := mintJWT(priv, id)
		if err != nil {
			log.Fatalf("mint %s: %v", id.name, err)
		}
		if err := writeSecret(ctx, cs, tokenNS, "jwt-"+id.name, map[string][]byte{
			"token":  []byte(tok),
			"sub":    []byte(id.sub),
			"intent": []byte(id.intent),
		}); err != nil {
			log.Fatalf("write secret jwt-%s: %v", id.name, err)
		}
		log.Printf("issued JWT for sub=%s intent=%s", id.sub, id.intent)
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

func mintJWT(priv *rsa.PrivateKey, id identity) (string, error) {
	now := time.Now().UTC()
	claims := jwt.MapClaims{
		"iss":    issuer,
		"sub":    id.sub,
		"intent": id.intent,
		"iat":    now.Unix(),
		"exp":    now.AddDate(10, 0, 0).Unix(),
		"aud":    "rogue-mcp",
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

