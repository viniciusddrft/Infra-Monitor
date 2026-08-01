package contracts_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

func contractPath(name string) string {
	return filepath.Join("..", "..", "contracts", name)
}

func TestOpenAPIIsSemanticallyValid(t *testing.T) {
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromFile(contractPath("openapi.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("OpenAPI inválido: %v", err)
	}

	ids := map[string]string{}
	operations := 0
	for path, item := range doc.Paths.Map() {
		for method, operation := range item.Operations() {
			operations++
			if operation.OperationID == "" {
				t.Errorf("%s %s sem operationId", method, path)
			} else if previous, exists := ids[operation.OperationID]; exists {
				t.Errorf("operationId %q duplicado em %s e %s %s", operation.OperationID, previous, method, path)
			} else {
				ids[operation.OperationID] = method + " " + path
			}
			if operation.Responses == nil || operation.Responses.Default() == nil {
				t.Errorf("%s %s sem resposta default", method, path)
			}
		}
	}
	if operations < 20 {
		t.Fatalf("contrato encolheu inesperadamente: %d operações", operations)
	}
}

func TestSSRFVectorsHaveStableShape(t *testing.T) {
	raw, err := os.ReadFile(contractPath("ssrf-vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		IPs []struct {
			IP string `json:"ip"`
		} `json:"ip"`
		Syntactic []struct {
			URL string `json:"url"`
		} `json:"sintaticos"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("JSON inválido: %v", err)
	}
	if len(doc.IPs) < 40 || len(doc.Syntactic) < 15 {
		t.Fatalf("vetores incompletos: ips=%d sintáticos=%d", len(doc.IPs), len(doc.Syntactic))
	}
	seen := map[string]bool{}
	for _, vector := range doc.IPs {
		if vector.IP == "" || seen["ip:"+vector.IP] {
			t.Fatalf("IP vazio ou duplicado: %q", vector.IP)
		}
		seen["ip:"+vector.IP] = true
	}
	for _, vector := range doc.Syntactic {
		if vector.URL == "" || seen["url:"+vector.URL] {
			t.Fatalf("URL vazia ou duplicada: %q", vector.URL)
		}
		seen["url:"+vector.URL] = true
	}
}
